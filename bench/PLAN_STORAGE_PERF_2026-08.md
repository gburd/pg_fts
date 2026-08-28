# Plan: close the storage/latency/size gaps without losing the banked wins

Status: PLAN (nothing edited). Grounds every phase in the 5-way benchmark
(`bench/data_5way/`, `bench/RESULTS_5WAY_LOADED_2026-08.md`), the prior
attempts (`NOTE_IMPACT_ORDERING.md`, `NOTE_PARALLEL_RANKED.md`,
`RESULTS_P1_P4.md`, `NOTE_SIZE_SPEED_REPLAN.md`), the sidecar design
(`DESIGN_DOCLEN_SIDECAR.md`), and `RELEASING.md`.

## The gaps (measured, 2.19M Wikipedia bodies, PG17, single-stream median/p99 ms)

| dimension | pg_fts | best competitor | factor | root cause |
|---|---|---|---|---|
| common ranked k10 | 28.6 / 28.9 | pg_search 4.5 / 4.7 | 6.4x | decode + score per posting; docid-order can't stop early |
| common ranked k100 | 30.0 | pg_search 6.9 | 4.3x | same |
| under load c32 (rare) | 3966 tps | pgts 8462 tps | 2.1x | heavier per-query CPU; no query parallelism |
| under load c32 (common) | 265 tps / 121ms | psearch 6300 / 5ms | ~24x | the common-term decode cost, amplified by concurrency |
| index size | 2089 MB | vchord 1453 MB | 1.44x | **doclen stored once per posting** |
| build time | 161 s | psearch 45 s | 3.6x | single-threaded flush/merge |

## The banked wins — must survive every phase

These are the reason to use pg_fts over the ranking-only engines. Any change
that regresses one is reverted.

- **count(\*) 4 ms** (dict-df fast path) vs pg_search 154 ms; pgts/vchord can't.
- **AND 2.9 ms, phrase 2.5 ms, prefix 1.9 ms** — real boolean/phrase/prefix
  operators the ranking-only engines lack.
- **Feature breadth**: @@@, count, phrase, prefix, fuzzy, regex, field-zones,
  BM25F, trusted=true, no-REINDEX upgrades, managed-service safety.
- **Correctness**: exact-by-recheck for everything the index over-selects;
  the ground-truth ranked-parity test (genuine_misses=0).

## What is ALREADY DISPROVEN — do not re-attempt

1. **Impact-ordered block-skip *directory*** (`NOTE_IMPACT_ORDERING.md`).
   Ordering docid blocks by an impact bound does NOT prune a common term: on real
   English text the per-block bounds cluster in a razor-thin band just above the
   top-k threshold (idf constant, thousands of blocks each hold a high-tf doc), so
   early-stop visited 99.7% of `year`'s blocks. Reverted. **A skip structure
   bolted onto docid-ordered blocks cannot deliver flat common-term latency.**
2. **Internal-DSM parallel-ranked CustomScan** (`NOTE_PARALLEL_RANKED.md`).
   ~30% Amdahl ceiling (70% of the query is scoring/heap/MVCC/executor the
   workers don't parallelize) AND workers didn't launch from ExecCustomScan at
   scale. Reverted. **Query parallelism must be a real partial-path/Gather AM
   that parallelizes visibility too, not an internal DSM around candidate gen.**

The conclusion both notes converge on: pg_search's flat latency is **a compact
columnar codec that decodes far less per candidate**, plus true query
parallelism. So the win is a **codec** change (Phase 2/3), not a skip structure.

---

## Phase 0 — pin the safety net (no format change, do FIRST)

Before touching any byte layout, lock down what "unchanged" means so every later
phase has an automatic kill signal.

- **0a. Ground-truth ranked-parity harness.** A repeatable script: build an
  index, for a set of rare/mid/common/AND queries compute the exact top-k by a
  seqscan `fts_bm25`/recompute, diff against the index top-k. Assert
  `genuine_misses = 0`. This already exists ad hoc from the exactness work
  (`NOTE_RANKED_EXACTNESS_LATENT.md`); make it a committed `bench/` script that
  takes a DSN + corpus and prints a pass/fail. **This is the gate for Phases 2-3
  where scoring math changes (quantization).**
- **0b. Latency + size regression baseline.** Capture current numbers into
  `bench/data_5way/` shape on a fixed corpus at 2M on a fixed instance type, so a
  phase's before/after is one instance, one corpus, `\timing` NSAMP>=200
  median/p99. Kill criterion for later phases references this.
- **0c. Fold TAP + fuzz into the per-phase gate.** Every phase must exit the full
  local gate (installcheck 17/18, tap 17/18, check-alloc, check-ascii, fuzz ALL
  CLEAN) AND 0a + 0b before it ships.

Cost: ~1 day. No format change, no release. Pure de-risking.

---

## Phase 1 — execution-path fixes (P2/P3): cheapest, whole-distribution, NO format change

The ranked scan re-reads the metapage 3x (`pg_fts_am_scan.c:1420,3680,3777`),
re-does dict lookups per term, over-fetches `wantk = Max(k*4, 64)`
(`:3971`), and churns a TupleTableSlot per candidate on the plain path
(`:2347`). None of this touches on-disk bytes.

- **1a. Cache the metapage once per scan** (`BM25ScanOpaque`), pass it down to
  `bm25_topk_candidates_range` instead of each re-reading. Keep the generation
  re-check (that's a cheap `bm25_read_meta_generation`, not a full read).
- **1b. Cache the per-term dict entry** (firstposting/firstoffset/df/idf) once at
  scan prime, not per pivot.
- **1c. Right-size the over-fetch.** `k*4` over-fetches 40 rows for a `LIMIT 10`.
  Measure `k*2` and an adaptive bump-on-miss; the adaptive-k engine already
  re-runs on demand, so the initial over-fetch can be smaller.
- **1d. Reuse one slot** on the plain (`@@@` non-ranked) path.

Expected (per ROADMAP P2/P3, and the 5-way rare/mid numbers): rare/mid ranked
from 4.4/5.7 ms toward ~3-4 ms, a few ms off common too. **This alone narrows
the under-load gap** because it cuts fixed per-query CPU, which is what
concurrency multiplies.

Kill: any latency regression on any band, or 0a fails. Ship as a **patch release
(1.4.2)**, C-only, no format change, no REINDEX. Independent of everything below.

---

## Phase 2 — doclen sidecar (P1): the size win + a decode win (format change)

Full design in `DESIGN_DOCLEN_SIDECAR.md` — this plan adopts it. Summary of the
decision and why it beats the failed P1:

- **Move doclen out of every posting into a per-segment sidecar**: one **quantized
  1-byte norm per doc** (Lucene/Tantivy SmallFloat: 3-bit mantissa / 5-bit
  exponent), on a `BM25_DOCLEN` page chain, referenced by a new
  `BM25SegMeta.doclenstart`. `avgdl` stays EXACT from `sumdoclen`/`ndocs` (already
  in the meta) — only the per-doc normalization denominator is quantized.
- Scoring's length term becomes a **256-entry table lookup** per cursor
  (`cache[b] = k1_1mb + k1b_inv_avgdl * decode(b)`), so `wand_contrib_cur`'s
  `norm = tf + cache[normByte]` — no divide, no per-posting doclen decode, and
  the block memcpy drops the doclen column (~56% of a dense block).
- **Why it's smaller and safe this time**: 1 byte/doc replaces ~2 B/posting x T;
  no impact-tier directory riding along (that was P4, separate); the 1.2.2
  vacuum-reclaim fix means the format actually shrinks on compaction; fixed 1-byte
  quantization has NO block-max widening; built extend-only with dedup-during-
  gather (no 400M-pair flat array = the P1 build OOM).

Format-change plumbing (mandatory, per `RELEASING.md`):

- Bump `BM25_VERSION` 3 -> 4; `bm25_check_meta` **accepts {3,4}** (dual-read).
- **Dual-read by segment**: `seg->doclenstart == InvalidBlockNumber` => old
  segment, postings carry doclen inline, score as today; else new segment, 2-column
  postings + sidecar. Both coexist in one index.
- **Lazy in-place migration**: `bm25_merge_segments` + `bm25_vacuum_compact`
  already rewrite segments — they write the new format. Index converges to v4 as
  merges/vacuum run. **No REINDEX.**
- No-op `pg_fts--1.4.2--1.5.0.sql` (SQL unchanged) + a **TAP upgrade test**: build
  on the prior release, `ALTER EXTENSION ... UPDATE`, load new `.so`, assert
  correct scores on old-format segments, then `fts_merge()`/`VACUUM` and assert
  the segment migrated (`doclenstart` set) and results still match.
- **Minor release 1.5.0.** CHANGELOG: doclen -> per-segment quantized sidecar,
  ~30-40% smaller, no REINDEX, migration completes on merge/vacuum.

Correctness gate (do NOT skip): Phase 0a must still pass. Quantization is lossy,
so document the bounded ordering error (Lucene accepts it). Fallback: exact
uint16 sidecar behind a reloption if the parity test is a hard product
requirement — still a big size win, just without widening immunity.

Expected: **index ~1.2-1.3 GB (from 2.1 GB), smallest or near-smallest in class**,
a **modest common-term latency win** (less decode + memcpy per posting), zero
count/AND/phrase/prefix regression (they don't score doclen on their hot path —
verify). Build time roughly unchanged (the sidecar is a streaming pass).

Kill: index not smaller after vacuum at 2M; any ranked regression >3%; parity
beyond the documented quantization bound; any win regresses.

---

## Phase 3 — the common-term ranked codec (the real 6x gap): format change, HARD

This is the actual pg_search gap and the hardest phase. The two notes rule out
the easy versions, so the design must be the "compact columnar codec that decodes
less per candidate" they point at — evaluate **in this order, stop at the first
that clears the kill criteria at 2M**:

- **3a. Impact-quantized postings stored highest-first (P4), WITH a hard-top-k
  WeakAND that genuinely skips low-impact tiers.** Distinct from the reverted
  *directory*: don't order docid blocks, **re-lay the postings themselves into
  impact tiers** (quantize tf-contribution into a few levels, store tier-by-tier
  highest-first per term). A moving top-k threshold then abandons a whole
  low-impact tier once k is full — the thing the razor-thin block bounds couldn't
  do. Prototype the tier layout + a single-term tiered scan; **instrument
  postings-scored-before-stop on `year`** BEFORE committing to the format. If it
  still scans >90% of postings on real text (as the directory did), STOP — this
  is the same clustering pathology and 3a is dead; go to 3b.
- **3b. Block-max WAND on a leaner block.** After Phase 2 the block already lost
  the doclen column. Push further: store tf pre-quantized to the impact level
  (not raw tf) so the block-max bound is tight AND scoring is a table lookup, and
  shrink `BM25BlockHdr`. This decodes strictly less per candidate even if it
  can't early-terminate — a decode-cost win that helps common terms and (more)
  helps under-load throughput. Lower ceiling than 3a but far lower risk (it's an
  extension of the proven WAND, not a new traversal).
- **3c. Query parallelism done right** (only if 3a/3b leave a gap and it's a
  must-win). NOT the reverted internal-DSM CustomScan. A **partial-path ordering
  AM** (`amcanparallel` KNN) where each worker produces *visible* ranked rows for
  its docid slice and the executor Gather-merges — so the ~40% serial visibility
  tail (the Amdahl ceiling that killed the last attempt) also scales. Large,
  PG-version-sensitive; sequence last.

Each of 3a/3b/3c is its own format/plan decision with its own release. **Do not
bundle.** Measure each in isolation against Phase 0b + 0a.

Kill (each sub-phase): no measured common-term latency win at 2M beyond noise
(the `NOTE_IMPACT_ORDERING` failure mode), OR any banked win regresses, OR parity
fails. A sub-phase that doesn't deliver is reverted and documented as a negative
result (like the two prior attempts) — the project rule.

---

## Phase 4 — build-time parallelism (nice-to-have): NO format change

pg_fts build is single-threaded flush/merge. PG supports parallel index build
(`ambuild` with `amcanbuildparallel` / parallel workers gathering into per-worker
runs, leader merges). This is orthogonal to the read-path format and doesn't risk
any query win.

- Parallelize the per-worker tokenize+sort+flush; leader does the final merge
  (which already exists). Target the psearch/vchord 3.6x build gap.
- Lower priority than 1-3 (build time rarely the operational bottleneck for a
  search workload), but cheap-ish and win-only. Ship whenever convenient.

Kill: any correctness divergence vs serial build (the parity test); revert.

---

## Sequencing & releases

| phase | change | format? | release | risk | banked-win risk |
|---|---|---|---|---|---|
| 0 | parity + baseline harness | no | none | none | none |
| 1 | execution-path (P2/P3) | no | 1.4.2 | low | low (guarded) |
| 2 | doclen sidecar (P1) | **yes** v4 | 1.5.0 | med | low (dual-read, gated) |
| 3a | impact-tier postings | **yes** | 1.6.0? | **high** | med (score math) |
| 3b | leaner impact block | **yes** | alt to 3a | med | low |
| 3c | partial-path parallel AM | no (planner) | later | high | low |
| 4 | parallel build | no | anytime | low | none |

Do **0 -> 1 -> 2** for certain (they're the size win + the cheap latency win +
de-risking, all low-banked-win-risk). Then attempt **3a**, and the instant the
`year` postings-scored instrumentation shows the clustering pathology, fall back
to **3b** (the safe decode-cost win). **3c/4** only if a specific customer needs
flat common-term latency or fast builds.

## One-paragraph rationale

Every gap traces to the docid-ordered, doclen-per-posting codec. Phase 2 removes
the per-posting doclen (the size gap, cleanly, with the P1 execution mistakes
designed out). Phase 3 attacks the per-candidate decode cost that is the real
source of the 6x common-term latency gap — approached as a *codec* change (what
the reverted experiments proved is the only thing that works), not a skip
structure or an internal-DSM parallel scan (both already disproven here). Phase 1
is the cheap down-payment that helps the whole distribution and under-load
throughput with no format risk. The banked wins (count, AND, phrase, prefix,
feature breadth, correctness) come from the rich index and are preserved by
dual-read + the parity gate on every phase.
