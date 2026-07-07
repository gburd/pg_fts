# pg_fts — Performance, Findings, and Project Handoff

**Audience:** the next engineer/agent who owns pg_fts.
**Status at handoff:** standalone extension, version 1.0 (internal feature series
reached 1.20 before the v1.0 release squash), builds against PostgreSQL 17/18/devel
via PGXS, qualifies clean (`--enable-cassert`, zero warnings, regression +
isolation + TAP green).
**The one-sentence truth:** pg_fts is a correct, feature-rich BM25 FTS extension
with a richer query language than any competitor, but on raw *ranked-retrieval
latency* it is the slowest of the three PostgreSQL BM25 extensions, and closing
that gap requires a posting-codec rewrite, not incremental tuning.

---

## 0. TL;DR for the new owner

- **What pg_fts is best at:** query-language breadth (boolean, phrase, NEAR,
  prefix, fuzzy, regex over one `@@@` operator), correctness (MVCC + WAL/crash
  safety, all page mutations via GenericXLog), and an **index-native `count(*)`**
  that no competitor has.
- **What pg_fts is NOT best at:** ranked top-k latency, index size, or build
  time. VectorChord-bm25 is ~8–40× faster on ranked queries with a ~5× smaller
  index; Timescale pg_textsearch is ~2–5× faster with a ~4× smaller index.
- **Why:** pg_fts stores full positional postings (to support phrase/NEAR) and
  per-document length, and decodes them with block-max WAND. The competitors use
  a compact columnar codec with a hard top-k early-termination that pg_fts's
  index format cannot match without a format rewrite ("format v3").
- **Things already tried to close the gap and REVERTED with evidence (do not
  re-attempt without reading the notes): impact-ordered postings, a reusable
  block buffer, an iterated parallel merge, and a parallel ranked CustomScan.**
  See `bench/NOTE_IMPACT_ORDERING.md`, `bench/NOTE_FORMAT_V3_PROFILE.md`,
  `bench/NOTE_PARALLEL_RANKED.md`.
- **The governing rule of this project:** never ship an optimization that is
  unsound, regresses another operation, or delivers no *measured* win. Several
  plausible ideas were built, measured, found wanting, and removed. Honor this.

---

## 1. Concept progression — start to finish

### 1.1 Origin and thesis
The goal was a native BM25 full-text search subsystem for PostgreSQL that
competes with the tsvector/GIN stack and with the Rust BM25 extensions
(ParadeDB pg_search/Tantivy, VectorChord-bm25) on features, latency, index size,
and TB-scale behavior — while **reusing PostgreSQL infrastructure** rather than
mmap'ing its own files: the buffer manager (not mmap), GenericXLog WAL, the
tsearch parser/dictionaries, the FSM, and MVCC.

Non-negotiable constraints, held throughout:
- MVCC-correct at all isolation levels; replication/crash safe. **100% of page
  mutations go through GenericXLog** (verified: ~15 GenericXLogStart cycles,
  zero raw XLogInsert/log_newpage/MarkBufferDirty/PageSetLSN/smgrwrite).
- Every change qualifies: clean `--enable-cassert` build, zero warnings,
  regression-green, before commit.
- Neutral, factual language in code/docs (marketing terms like "next-generation"
  were explicitly removed).

### 1.2 The reviewable feature series (extension 1.0 → 1.19)
The extension was built as a sequence of independently-qualified stages, each one
version bump. The arc:
- **Types & operators (1.0–1.2):** `ftsdoc`/`ftsquery` types,
  `to_ftsdoc()`/`to_ftsquery()`, the `@@@` match operator, `fts_bm25()` scoring.
- **The `bm25` access method (1.3):** a real index AM, bitmap scan, GenericXLog
  crash-safe. This is the heart of the project.
- **Ranking variants (1.4):** lucene, robertson, atire, bm25+, and later bm25l
  — full parity with rank_bm25 / plpgsql_bm25's algorithm set.
- **Presentation (1.5):** `fts_highlight()`, `fts_snippet()`.
- **Migration (1.6):** `tsquery_to_ftsquery()` + a cast.
- **Corpus statistics (1.7):** index-maintained N, sum(doclen), per-term df — the
  data BM25 needs, kept in the index so ranking needs no heap recheck.
- **Incremental maintenance (1.8):** INSERT appends to a pending list; no REINDEX.
- **Phrase queries (1.9):** per-term positions, ftsdoc on-disk format v2. **This
  is where the index started carrying positions — the feature that later
  explains pg_fts's larger index and slower ranked scans.**
- **External-content / expression indexing (1.10):** `CREATE INDEX ... USING
  bm25(to_ftsdoc('english', body))`.
- **Fuzzy + regex (1.11):** `term~k` (Levenshtein DFA) and `/re/` terms, with a
  trigram pre-filter (`pg_fts_trgm*`).
- **Observability + tuning (1.12–1.18):** stats functions, BM25 variants exposed,
  background merge of the pending list on VACUUM/`fts_merge()`, config-normalized
  query terms, `fts_index_nsegments()`.
- **Fast counts (1.19):** `fts_count()` — MVCC-correct bulk count from the index
  via the visibility map.

### 1.3 The segmented rebuild (the biggest architectural decision)
Early on the index was a single monolithic structure. It was rebuilt into a
**Lucene/Tantivy-style segmented container**: immutable segments, each with its
own term dictionary (+ a sparse block index), FOR-128-packed posting lists
carrying (docid gaps, tf, doclen), a per-block header with `first_docid` and
`max_tf`, plus per-segment livedocs (tombstones). A **size-tiered merge policy**
(threshold 8, tier_min 4, size_factor 3.0) compacts segments in the background
(VACUUM) or on demand (`fts_merge()`). Query time runs **block-max WAND** (short
queries) or **MaxScore** (≥4 terms) with lazy per-column decode (pruned blocks
never decode tf/doclen).

This is a good, standard design and it is *correct*. It is also the reason the
index is large and ranked scans are decode-bound — see §3.

### 1.4 Tombstones, MVCC, and the reused-heap-slot bug
DELETE/UPDATE record per-segment tombstones (via `ambulkdelete`), stored as a
vendored **sparsemap** bitmap. A subtle correctness bug was found on *real*
Wikipedia (not synthetic data): a heap slot freed by one doc and reused by
another must not inherit the first's tombstone. Fix: tombstones are applied
**per-segment** (a cursor never emits a docid deleted *in its own segment*), and
pending docs are collected separately and unioned after the per-segment filter.
Lesson carried forward: **test on real corpora; synthetic Zipfian data hides
whole classes of bugs** (this one, and the codec-size differences in §3).

### 1.5 Hardening for upstream review
Committer-review-style passes fixed: a 64-byte-term-prefix collision that lost
postings (→ BuildTerm.next chaining); `bm25_canreturn` wrongly claiming a
covering index (→ returns false, so `count(*)` uses a bitmap heap scan and
`fts_count()` is the fast path); recv-wire-count DoS hardening; dead-code
removal; and CI portability across Linux 64/32-bit, macOS, MSVC, and MinGW
(notably a 32-bit sparsemap `SM_IDX_MAX` truncation and an alignment fix).

### 1.6 Parallelism (1.20-era)
- **Parallel index build** (`amcanbuildparallel`): each worker scans a slice and
  flushes segments; segment writes serialized via the relation extension lock.
  ~3.9× faster build at 2M (34 min → ~9 min for the scan phase).
- A **regression was found and fixed**: the parallel build initially skipped the
  final merge, leaving a multi-segment index that regressed common-term ranked
  ~2× (a scan traverses every segment's postings). Fix: both build paths compact
  to one segment.
- **Concurrent-write fix:** the merge held the relation extension lock around the
  *entire* segment write, serializing workers' writes. Changed to hold it only
  around the single `P_NEW` page extension, so participants write concurrently.

### 1.7 Physical-bloat reclaim (`fts_vacuum`, 1.20)
Ordinary merges recycle freed pages to the FSM but never shrink the relation, so
a freshly built/merged index stays physically large. `fts_vacuum(regclass)`
compacts to one segment reusing the **lowest** free blocks (low-page-biased
allocator, so live pages pack at the front), then truncates the free tail back to
the OS. Runs automatically during VACUUM when the index is ≥25% free.

### 1.8 The COUNT pushdown (CustomScan, 1.20)
A `create_upper_paths_hook` CustomScan (`FtsCount`) transparently answers
`SELECT count(*) ... WHERE col @@@ q` from the index (the `fts_count` fast path)
instead of a bitmap heap scan — no need to call `fts_count()` explicitly. This is
the one CustomScan that survived; see §4 for the ranked one that didn't.

### 1.9 Standalone extraction (this session's end state)
The extension was extracted from its PostgreSQL-contrib development tree into a
standalone, out-of-tree project (`~/ws/pg_fts`) that builds against an installed
PostgreSQL via PGXS. It was then further prepared for a v1.0 public release
(Nix flake, meson build, multi-PG CI, SQL squashed to a single
`pg_fts--1.0.sql`, version reset 1.20 → 1.0).

---

## 2. Benchmark methodology (reproduce exactly)

- **Hardware:** EC2 **r7i.4xlarge** (16 vCPU Sapphire Rapids, 123 GB), Fedora 43.
  Sapphire Rapids matters: i4i's Ice Lake cores are ~15% slower single-thread and
  gave 34-min vs 21–29-min builds. Bare-metal not required for these numbers.
- **PostgreSQL:** 17.10 built from source (`--without-icu`, `-O2`). Competitors
  (VectorChord, pg_search) target released majors, so PG17 (not devel) is used
  for cross-engine runs. pg_fts itself builds on 17/18/devel.
- **Server config:** `shared_buffers=32GB`, `maintenance_work_mem=8GB`,
  `work_mem=256MB`, `jit=off`, **autovacuum=off during runs**,
  `max_parallel_workers=16`, `max_parallel_maintenance_workers=8`,
  `max_parallel_workers_per_gather=8`.
- **Corpus:** `wikimedia/wikipedia` 20231101.en, first **2,188,038** articles,
  `body` column. Loader streams HF parquet → TSV (`bench/get_wikipedia.py` /
  `get_wiki2m.py`). ~6.5 GB TSV.
- **Analyzers, matched:** pg_fts and pg_textsearch use PostgreSQL `english`
  (Snowball); VectorChord uses `to_tsvector('english', …)`. Same stemming/
  stopwords → comparable. (ParadeDB pg_search uses Tantivy `en_stem`, which
  differs — its counts differ by design; noted in the older results.)
- **Latency:** median of 9, warm cache, **one engine at a time** (uncontended;
  running engines concurrently thrashes cache and inflates numbers — a real
  mistake made once, then avoided).
- **Operational hazards learned:**
  - Fedora mounts `/tmp` as tmpfs (RAM-backed, quota'd) — put PGDATA and the
    corpus on the real disk (`/data`), never `/tmp`, or you get `PANIC: Disk
    quota exceeded` with disk free.
  - **Never restart the cluster during a parallel operation** and never
    `pg_terminate_backend` a parallel worker — it can wedge shutdown. Let it
    finish, or `stop -m immediate` if truly stuck (crash recovery replays WAL).
  - A stuck autovacuum can wedge a restart; `autovacuum=off` on bench boxes.
  - `tar xf *.bz2` on Fedora needs `bzip2` (it shells out to `lbzip2`/`bzip2`).
  - SG **must** be locked to your IP (`x.x.x.x/32`), never `0.0.0.0/0` — a prior
    account was terminated for a `0.0.0.0/0` SG (policy violation).

---

## 3. Findings with raw numbers

### 3.1 The definitive 3-way (2.19M Wikipedia, PG17.10, r7i.4xlarge, median/9 warm)
Engines: pg_fts 1.20 · VectorChord-bm25 HEAD · Timescale pg_textsearch 1.4.0-dev.
Full detail: `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md`.

**Index size + build:**

| engine        | index size | build                        |
|---------------|-----------:|------------------------------|
| VectorChord   | 1367 MB    | ~2.3 min                     |
| pg_textsearch | 1831 MB    | ~4.5 min                     |
| pg_fts        | 7541 MB    | ~26 min build + ~41 min `fts_vacuum` |

**Ranked top-10 (ms):**

| query           | pg_fts | pg_textsearch | VectorChord |
|-----------------|-------:|--------------:|------------:|
| rare (slovakia) | 15.8   | 3.3           | **1.6**     |
| mid (hungary)   | 13.4   | 3.5           | **1.7**     |
| common (year)   | 39.9   | 13.0          | **1.7**     |

**Ranked top-100 (ms):**

| query         | pg_fts | pg_textsearch | VectorChord |
|---------------|-------:|--------------:|------------:|
| common (year) | 74.1   | 17.0          | **1.9**     |

**Ranked AND top-10 (ms):**

| query      | pg_fts | pg_textsearch | VectorChord |
|------------|-------:|--------------:|------------:|
| rare&mid   | 24.4   | 4.0           | **1.9**     |
| common&mid | 17.6   | 8.5           | **1.7**     |

**Counts (ms) — pg_fts-only capability** (neither competitor exposes a
match/count predicate; both are ranking-only, `<&>` / `<@>`):

| query         | pg_fts fts_count | pg_fts count(*) pushdown |
|---------------|-----------------:|-------------------------:|
| rare          | 40.8             | 44.5                     |
| common (736k) | 458              | 547                      |

### 3.2 vs GIN + ts_rank (2M Wikipedia) — where pg_fts *does* win big
Full: `bench/RESULTS_WIKIPEDIA_2M.md`. pg_fts crushes the stock tsvector/GIN +
`ts_rank` stack on ranked retrieval because ts_rank must fetch and sort every
match:

| query                            | pg_fts | GIN+ts_rank | pg_fts speedup |
|----------------------------------|-------:|------------:|---------------:|
| ranked top-10 (mid & mid)        | 18.1   | 49.6        | 2.7×           |
| ranked top-10 (common & mid)     | 15.4   | 64.6        | 4.2×           |
| ranked top-100 (common)          | 75.3   | 3028.7      | **40×**        |
| ranked top-10 (common & common)  | 50.0   | 1640.6      | **33×**        |
| plain count / boolean AND        | ~tie (both bitmap scans)          |

So the framing matters: **pg_fts is far better than the built-in FTS**, and far
behind the specialist Rust BM25 extensions. GIN/RUM/tsearch were dropped from the
final comparison at the owner's direction precisely because they are known-slow
and not the real competition.

### 3.3 vs ParadeDB pg_search 0.24.1 (earlier 2M run)
Full: `bench/RESULTS_VS_PGSEARCH_WIKI.md`. pg_search (Tantivy) also beats pg_fts
on ranked retrieval (~9 ms flat) and common-term count, while pg_fts had the
smaller index at that time (3590 MB vs 5574 MB) and won selective counts
(`fts_count` rare 1.9 ms vs 9.1 ms). Same story as VectorChord: the Rust engines'
columnar codec + query parallelism win ranked latency.

### 3.4 The optimizations that HELPED (measured, kept)
- **Word-oriented FOR decode** (replacing bit-by-bit unpack): **5.7×** faster in
  isolation; cut common-term `fts_count` ~3× at one point. Kept. On-disk format
  unchanged (faster reader). Self-check in the commit; see
  `bench/RESULTS_MERGE_VACUUM_DECODE.md`.
- **Parallel build + concurrent-write extension lock:** ~3.9× build speedup,
  byte-identical output. Kept.
- **`fts_vacuum` (compact + truncate):** reclaims physical bloat without REINDEX.
  Local 300k: 206 MB → 70 MB (one pass) → 35 MB (second pass, the floor). At 2M
  real Wikipedia it converged 12 GB → 7.5 GB over two ~20-min passes — see the
  caveat in §5. Kept.
- **COUNT pushdown CustomScan:** transparent `count(*) WHERE @@@` at index speed
  (~3× vs bitmap heap scan on a common term). Kept.

### 3.5 The optimizations that did NOT help (measured, REVERTED)
Read the notes before re-attempting any of these.

- **Impact-ordered posting directory (the original "format v3")** —
  `bench/NOTE_IMPACT_ORDERING.md`. A per-term impact-ordered block skip directory
  that intended best-first early termination. Built, proven exact. On 2M real
  Wikipedia it **visited 99.7% of blocks anyway** (`year`: 5282/5296): within one
  term the per-block impact bounds cluster in a razor-thin band just above the
  top-k threshold, so best-first ordering cannot prune. Reverted.
- **Reusable per-cursor block buffer** — `bench/NOTE_FORMAT_V3_PROFILE.md`.
  Profiling fingered a per-block `palloc`; replacing it with a reusable buffer
  was measured **slower** (top-100 common 15 → 20 ms): the palloc is only ~1.2%
  (bump allocator), and a larger fixed buffer hurt cache. Reverted.
- **Iterated parallel merge** — merging the segment tree to one segment across
  passes was measured **worse** at 2M (32 vs 27 min): each pass rewrites data
  (write amplification), and the final reduction is a single multi-GB output
  write no partition scheme parallelizes. Reverted to single-pass.
- **Parallel ranked CustomScan** — `bench/NOTE_PARALLEL_RANKED.md`. A CustomScan
  that fanned WAND candidate generation across workers by docid range. Verified
  byte-identical to serial. But **no measured win** at 2M: the common-term query
  is only ~30% decode+WAND (parallelizable) and ~70% scoring/heap/visibility
  (leader-serial) — Amdahl caps it at ~30% — and workers didn't reliably launch
  from inside `ExecCustomScan`. Reverted; the COUNT pushdown (its sibling) was
  kept.

### 3.6 AIO for writes — considered, rejected (with reasons)
Documented in CAPABILITIES.md. Two independent blockers: (1) this PG tree's
buffer manager has AIO for *reads only* (no buffer-manager write path; using the
low-level `pgaio_io_start_writev` would bypass shared buffers and break the
GenericXLog invariant); (2) the merge tail is **CPU-bound re-encode**, not I/O
wait (the index is resident in 32 GB shared_buffers), so async writes hide
nothing. AIO is not the lever.

---

## 4. Root-cause analysis: why pg_fts loses ranked latency

This is the single most important thing for the new owner to internalize, backed
by a `perf --no-children` profile of the common-term ranked query
(`bench/NOTE_FORMAT_V3_PROFILE.md`):

| self time | function                    | what it is                       |
|-----------|-----------------------------|----------------------------------|
| 19.5%     | `bm25_for_unpack`           | docid decode (already 5.7×-tuned)|
| 9.7%      | `wand_load_block`           | memcpy payload + gap→docid loop  |
| ~3%       | `hash_bytes`/`hash_search`  | per-block buffer lookup          |
| ~65%      | scoring / top-k heap / visibility / executor | the rest        |

Two structural facts:
1. **Block-max WAND cannot prune common English terms.** idf is constant across
   a term's blocks, and real English gives thousands of blocks each containing a
   high-tf doc, so per-block score bounds cluster just above the k-th score.
   WAND therefore loads ~every block for a common term. This is *not* a bug; it
   is a property of the docid-ordered positional format. (Confirmed twice: once
   by the impact-ordering experiment, once by the flat profile.)
2. **The codec is heavy by design.** pg_fts stores positions (phrase/NEAR),
   tf, and doclen per posting. VectorChord/pg_textsearch store a compact columnar
   bag-of-words with no positions, decode far less per candidate, and — crucially
   — VectorChord's block-WeakAND takes a hard `bm25.limit` top-k and *actually
   early-terminates*.

**Conclusion:** the ranked gap is a **posting-codec + early-termination**
problem, and a codec change is capped at ~30% of the query anyway (the other 70%
is scoring/heap/visibility/executor). No skip structure bolted onto the current
docid-ordered positional blocks will close it — the two attempts prove that.

---

## 5. Known weaknesses / rough edges the new owner should fix or watch

1. **`fts_vacuum` at scale is slow and doesn't fully converge in one pass.** At
   2M it took two ~20-min single-threaded rewrites to go 12 GB → 7.5 GB. The
   rewrite temporarily *grows* the file before truncating. Options: make it
   converge in one pass (relocate + truncate in a single rewrite), parallelize
   the rewrite, or store fewer positions when phrase support isn't needed.
2. **Large index because of positions.** If a workload doesn't need phrase/NEAR,
   a "no-positions" index option would make pg_fts much smaller and faster and
   more directly comparable to the competitors. Strong candidate feature.
3. **Common-term count is ~460 ms** at 736k hits (collect all matching TIDs +
   MVCC visibility). Fine for selective terms (rare ~2–40 ms); not fast for
   common ones. A CustomScan aggregate that counts via the VM without
   materializing the full TID set could help.
4. **The v1.0 release squash dropped the DEFERRED.md and bench/NOTE_*.md** from
   the standalone tree at one point. This handoff restores them. **Keep them** —
   they are the record of what was tried and why it failed, and prevent
   re-litigating dead ends.
5. **Parallel merge / parallel-context launch from inside executor nodes is
   fragile at scale** (workers often didn't launch on EC2 despite free slots).
   If you revisit parallel query, use a real partial-path / Gather plan, not an
   internal DSM inside `ExecCustomScan`.

---

## 6. Ideas for future work (ranked by expected payoff vs effort)

1. **Format v3: compact columnar codec + hard top-k early-termination.** THE
   lever for ranked latency. Store the docid set as a rank/select-friendly
   structure (Roaring-style) + a quantized-impact sidecar, separate from the
   optional positions. Give the WAND/WeakAND loop a real `LIMIT k` it can
   early-terminate on (as VectorChord does). This is a substantial rewrite and
   the *only* thing shown capable of closing the gap. Everything else is noise
   until this is done.
2. **Optional no-positions index mode.** Cheap-ish, high value: a `WITH
   (positions=off)` that omits positional postings for phrase-free workloads —
   smaller index, faster build, faster scan. Makes pg_fts competitive on size
   for the common case while keeping phrase support opt-in.
3. **Faster/converging `fts_vacuum`** (§5.1) and a **VM-only common-term count**
   (§5.3).
4. **SIMD FOR-unpack** of the docid column — bounded ~5–8% whole-query win,
   portability-gated (SSE/NEON kernels). A decode micro-opt, not a format change;
   only worth it after (1).
5. **Real partial-path parallel ranked scan** that also parallelizes visibility
   (not the internal-DSM CustomScan that was reverted) — only worthwhile if the
   codec work lands first, since it's Amdahl-bound otherwise.
6. **Positioning, not just speed:** pg_fts's honest niche is *rich query
   language + index-native count + correctness*, not raw ranked QPS. If the goal
   is adoption, lean into phrase/fuzzy/regex/NEAR and hybrid filter+rank, where
   the competitors are weak, rather than chasing VectorChord on flat top-k.

---

## 7. Where everything lives

- **Standalone tree:** `~/ws/pg_fts` (git repo, branch `main`). Builds with
  `make PG_CONFIG=…`; test with `make installcheck`. Also a Nix flake and meson
  build were added during the v1.0 prep.
- **Original dev tree (source of truth for the full 1.0→1.20 history and all
  notes):** `~/ws/postgres/fts/contrib/pg_fts` on the `fts` branch of the
  gburd/postgres fork (pushed to `origin/fts`). The DEFERRED.md and the three
  `bench/NOTE_*.md` live there and are copied into the standalone `bench/` by
  this handoff.
- **Benchmark result files** (raw numbers): `bench/RESULTS_*.md` and
  `bench/NOTE_*.md` in the standalone tree.
- **Vendored dependency:** `vendor/sm.c` + `vendor/sm.h` (sparsemap), public
  symbols namespaced to `__pg_bm25_*`; `sm.h` byte-identical to upstream, `sm.c`
  differs only by the prefix block.

## 8. Competitor query cheat-sheet (for future benchmarks)

- **pg_fts:** `WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','q')`
  match; `ORDER BY to_ftsdoc(...) <=> to_ftsquery(...) LIMIT k` ranked;
  `fts_count('idx', to_ftsquery(...))` or transparent `count(*) WHERE @@@`.
- **VectorChord-bm25:** column `emb tsvector = to_tsvector('english',body)`;
  `CREATE INDEX ... USING bm25 (emb bm25_ops)`; `SET search_path TO
  public,tokenizer_catalog`; `SELECT set_config('bm25.limit','k',false)`;
  `ORDER BY emb <&> to_bm25query(to_tsvector('english','q'),'idx'::regclass)
  LIMIT k`. Needs `vchord_bm25,pg_tokenizer` in shared_preload_libraries.
  pgrx 0.17.0; pg_tokenizer pgrx 0.16.1. Builds via `cargo pgrx install`.
- **Timescale pg_textsearch:** `CREATE INDEX ... USING bm25(body) WITH
  (text_config='english')`; `ORDER BY body <@> 'q' LIMIT k` (negative score,
  ASC). PGXS C build (`make && make install`); needs `pg_textsearch` in
  shared_preload_libraries. Ranking-only, no match/count predicate.

---

*Written at the end of the development/benchmark phase, before handoff. All
numbers are measured on the environment in §2; nothing here is projected. The
project's discipline — measure, and delete what doesn't pay — produced several
of the most useful results (the negative ones). Keep it.*
