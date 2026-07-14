# pg_fts 0.3.5 ranked-scan hot-path profile — Step 0 (measurement gate)

Pure profiling run. NO code changes. This is the measurement gate demanded by
bench/NOTE_SIZE_SPEED_REPLAN.md §1b/§3/§3a: each candidate optimization
(C1–C5) must show perf self-time > ~1 ms in the class it targets BEFORE it is
worth attempting. The last attempt (P1–P4) optimized costs that weren't
dominant and regressed everything.

## Provenance

- **pg_fts**: v0.3.5, HEAD `c37bc0f` (working tree), AM name `fts`, format v2,
  positions=OFF.
- **PostgreSQL**: 17.10 from source, built WITH frame pointers:
  `CFLAGS="-O2 -g -fno-omit-frame-pointer"` (release codegen + frame pointers
  for callgraph). pg_fts built the same: `make COPT="-O2 -g -fno-omit-frame-pointer"`.
- **Instance**: EC2 r7i.4xlarge (matches all prior pg_fts benchmarks),
  us-east-2, Fedora Cloud, 300 GB gp3 on /data. (id recorded below)
- **GUCs**: shared_buffers=64GB, maintenance_work_mem=16GB, work_mem=256MB,
  jit=off, autovacuum=off, max_parallel_maintenance_workers=8,
  max_parallel_workers=16, max_parallel_workers_per_gather=8.
- **Profiling GUCs (force AM ordering scan)**: enable_seqscan=off,
  enable_bitmapscan=off, max_parallel_workers_per_gather=0. EXPLAIN-confirmed
  Index Scan + Order By.
- **Corpus**: wikimedia/wikipedia 20231101.en, first 2,188,038 articles, body
  column. fts index: `CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('english', body))`.
  VACUUM ANALYZE + `fts_vacuum('docs_fts')` (full compaction) before profiling.
- **df verification target**: slovakia=10874, hungary=24095, year=734881.
- **Query form (all classes)**:
  `SELECT id FROM docs WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','TERM')
   ORDER BY to_ftsdoc('english',body) <=> to_ftsquery('english','TERM') LIMIT K;`
- **perf**: `perf record -g --call-graph dwarf -p <backend_pid>`,
  `perf report --stdio --no-children` for SELF-time.
- kernel.perf_event_paranoid=-1 for user callgraph profiling.

## Status

- **Instance id**: `i-0b1351455d46bce0f` (r7i.4xlarge = 16 vCPU / 128 GiB,
  us-east-2, owner=gburd-agent, Name=pgfts-prof-20260714-084104). Per-session
  keypair `pgfts-prof-20260714-084104`, SG `sg-073910dc224ccf414`
  (ingress 22 from 73.4.58.126/32 only).
  (Two earlier launches were terminated cleanly — the ssh-agent offered too many
  keys first, hitting "Too many authentication failures"; fixed with
  IdentitiesOnly=yes.)
- **TERMINATED**: yes — `i-0b1351455d46bce0f` confirmed `terminated`, SG + keypair
  deleted, `.pem` removed. No orphaned instances/SGs/keypairs under owner=gburd-agent.

- [x] instance launched
- [x] PG 17.10 + pg_fts 0.3.5 built with frame pointers (`-O2 -g -fno-omit-frame-pointer`)
- [x] corpus loaded (2,188,038 articles)
- [x] fts index built (positions=off, 7626 MB), VACUUM ANALYZE + fts_vacuum done
- [x] df verified (english-stemmed): slovakia=10889 (t 10874), hungary=24133
      (t 24095), year=735658 (t 734881) — all within ~0.1%, corpus matches
- [x] latency baselines captured
- [x] perf profiles captured (self + children, `--call-graph dwarf`)
- [x] instance TERMINATED

---

## 0.3.5 baseline latency (ms, median of 15 warm, forced AM ordering scan)

| Class | top-10 | top-100 |
|---|---:|---:|
| rare (slovakia, df 10.9k) | **13.18** | 33.42 |
| mid (hungary, df 24.1k) | **10.67** | 43.62 |
| common (year, df 736k) | **35.01** | 69.69 |
| AND hungary&year (top-10) | **11.36** | — |
| AND slovakia&hungary (top-10) | **20.57** | — |

EXPLAIN confirmed `Limit -> Index Scan using docs_fts ... Index Cond (@@@) +
Order By (<=>)` for every class (see explain output pulled to
/tmp/pgfts_prof_out/explain.txt). These are the clean 0.3.5 numbers to compare
any future optimization against.

---

## THE HEADLINE FINDING (reframes the whole optimization program)

**None of C1–C5 is the bottleneck. The dominant cost of every ranked query is
`to_ftsdoc('english', body)` RE-ANALYSIS in the executor** — the ORDER BY /
projection expression is re-tokenized + Snowball-stemmed on each row the scan
returns (`to_ftsdoc_byid -> fts_analyze_with_config -> parsetext -> LexizeExec
-> dsnowball_lexize -> english_UTF_8_stem`). This is NOT inside pg_fts.so's scan
at all; it is `ExecProject`/`ExecScan` re-evaluating the expression-index's
underlying expression on heap tuples.

Inclusive share of total query time (perf children, dwarf callgraph):

| Class | `to_ftsdoc` re-analysis | ≈ ms | index scan (`fts_search_wand`) |
|---|---:|---:|---:|
| rare slovakia top-10 | **83.2%** | ~10.96 | ~11% (blob 10.7% self) |
| common year top-10 | ~40% | ~14.0 | **~60%** |
| common year top-100 | **67.6%** | ~47.1 | ~32% |
| AND slovakia&hungary top-10 | **87.6%** | ~18.0 | small |
| AND hungary&year top-10 | lower (year common) | — | scan-dominated |

Mechanism: the query form is
`SELECT id FROM docs WHERE to_ftsdoc('english',body) @@@ q
 ORDER BY to_ftsdoc('english',body) <=> q LIMIT k`.
The `<=>` distance is answered by the index (amcanorderbyop), but the executor
still materializes `to_ftsdoc('english',body)` on every returned heap row (Index
Cond recheck / ExecProject), which re-runs the full english text analysis — the
same ~3 GB-of-prose analysis that makes CREATE INDEX single-threaded slow, now
paid per candidate row at query time. For a rare term that returns ~few thousand
rows this is the entire query; for common top-100 it is two-thirds of it.

**Implication:** the biggest ranked-latency win available is *not* any of C1–C5.
It is eliminating the per-row `to_ftsdoc` re-analysis — e.g. an index-only /
ordering path that returns id + score without re-deriving the ftsdoc from the
heap body, or not putting `to_ftsdoc(body)` in the ORDER BY expression at all
(the distance is index-supplied). That is a query-form / planner-integration
question, orthogonal to the C1–C5 exec micro-optimizations. (Worth noting: real
applications that write `ORDER BY col <=> q` with a stored `ftsdoc` column, not
a recomputed `to_ftsdoc(text_col)` expression, would NOT pay this — so part of
this is a benchmark-query-form artifact. But every prior pg_fts benchmark used
this exact expression-index form, so the historical latency numbers all carry
this re-analysis tax, and it dwarfs everything C1–C5 targets.)

---

## Per-function self-time inside pg_fts.so + the index-scan subtree

Because `-O2` inlined the WAND scan into one symbol
(`bm25_topk_candidates_range.constprop.0`), the per-function detail comes from
the children (inclusive) tree of the index-scan side. For **common year top-10**
(scan ≈ 60% of the 35.0 ms query, i.e. ~21 ms of scan):

| Node (inclusive) | % of query | ≈ ms | what it is |
|---|---:|---:|---|
| `fts_search_wand` (scan total) | 60.0 | ~21.0 | whole WAND scan |
| `wand_contrib_cur` | 27.6 | ~9.7 | per-posting BM25 contribution |
| `bm25_for_get` | 21.6 | ~7.6 | tf/doclen extract + idf/tf scoring |
| `wand_load_block` | 6.6 | ~2.3 | block load + decode |
| `bm25_for_unpack` | 3.8 | ~1.3 | FOR decode |
| ReadBuffer/Pin/BufferAlloc chain | ~2.7 | ~1.0 | block I/O (warm) |
| `bm25_docid_to_tid` | 1.2 | ~0.4 | docid→tid map |

So, of the index-scan slice: **scoring (`wand_contrib_cur`/`bm25_for_get`) ≈ half
the scan, decode+load (`wand_load_block`/`bm25_for_unpack`/ReadBuffer) ≈ 4.6 ms
(~13% of the whole query, ~22% of the scan).** Top-k heap and visibility
(`table_index_fetch_tuple`, slot mgmt) never rise above the perf floor.

For **AND hungary&year top-10** the index side is traversal-heavy:
`wand_seek` 23.8%, `wand_load_block` 15.5% -> `bm25_for_unpack` 10.6%,
ReadBuffer chain ~3%, `bm25_lookup_dict` 2.16%. Decode is a bigger relative
slice on AND than on single-term (more blocks skipped/loaded per match).

### Confirm/refute the replan's cost model
- **Common-term "~65% scoring/heap/visibility/executor, ~30% decode+load":**
  PARTIALLY REFUTED as stated. Within the *index scan*, scoring ≈ 50% and
  decode+load ≈ 22% — roughly the shape predicted. But the model omitted the
  real elephant: ~40–68% of the *whole query* is `to_ftsdoc` re-analysis in the
  executor, not scan work at all. "heap/visibility/executor" turned out to mean
  "executor re-analysis", not slot/visibility overhead (which is ~0).
- **Rare-term "dominated by per-query fixed cost, not decode":** CONFIRMED that
  it's not decode — but the fixed cost is `to_ftsdoc` re-analysis (83%), NOT the
  metapage/dict reads (C1/C2) the replan hypothesised. C1/C2 are ~0.

---

## VERDICTS on C1–C5 (the measurement gate)

Gate = perf self/inclusive time > ~1 ms in the class the candidate targets.

| # | Candidate | Measured in target class | Verdict |
|---|---|---|---|
| **C1** | metapage cache (`bm25_read_meta`/memcpy) | **0 samples anywhere** (rare top-10 or any) | **SKIP** — ~0.00 ms, far below 1 ms. The ~6 KB warm memcpy is invisible. |
| **C2** | dict double-lookup (`bm25_lookup_dict`) | 2.16% of AND-hungary-year (~0.25 ms); **0** in rare | **SKIP** — max ~0.25 ms, below 1 ms. |
| **C3** | reuse TupleTableSlot (`table_slot_create`/`MakeTupleTableSlot`/`ExecDropSingle`) | **0 samples in common_year_top100** (or anywhere) | **SKIP** — ~0.00 ms. Flagged as "most likely real win"; **REFUTED**. The wantk candidate-slot loop is below the perf floor. |
| **C4** | right-size wantk over-fetch (`table_index_fetch_tuple`) | **0 samples anywhere** | **SKIP** — ~0.00 ms. Visibility fetch is negligible; shrinking wantk cannot help a cost that isn't there. |
| **C5** | AND collect-matches gate (`bm25_collect_matches`) | **0 samples in either AND report** | **SKIP** — ~0.00 ms. The exact-match gate is NOT the dominant cost of AND ranked; refuted. |

**Every C1–C5 is SKIP.** They optimize costs that are at or below the perf
measurement floor at 2.19M scale. This is exactly the trap the replan warned
about ("the last attempt optimized costs that weren't dominant and regressed
everything") — the gate did its job and stopped all five before any code changed.

---

## What IS worth attention (ranked by measured cost)

1. **`to_ftsdoc` per-row re-analysis (40–88% of every ranked query).** By far the
   largest lever. Not a scan micro-opt — it's the ORDER BY/projection
   re-evaluating the expression-index expression on heap rows. Options to explore
   (all need their own measurement before commit): avoid re-deriving ftsdoc when
   the distance is index-supplied; index-only-style score return; or document
   that a stored `ftsdoc` column (vs `to_ftsdoc(text_col)` expression) sidesteps
   it. Caveat: partly a benchmark-query-form artifact — confirm on the real
   application query shape first.
2. **Scoring inside the scan (`wand_contrib_cur`/`bm25_for_get`, ~half the scan,
   ~7–10 ms on common).** Irreducible BM25 work per posting; only impact-ordered
   postings + hard top-k would cut it, which the replan (§1c, §5) already rules
   out as too risky. Leave it.
3. **Decode+load on AND (`wand_load_block`/`bm25_for_unpack`, ~15–26% of AND).**
   The only place a format/codec change could measurably help, and only for AND
   traversal — consistent with the replan's "codec changes capped at the decode
   slice" and the doclen-column being the widest FOR column. Still a format bet
   (§C6), gated and size-coupled; not an exec win.

**Bottom line:** the replan's honest conclusion holds and is now measured — the
exec-only micro-opts (C1–C5) are rounding-error at 2.19M and must not be
attempted. The real ranked-latency cost is executor-side `to_ftsdoc`
re-analysis, which is a query-form/planner question outside the C1–C5 scope.

_(raw perf reports: /tmp/pgfts_prof_out/report_*_self.txt and *_children.txt on
the control host; latency.txt, explain.txt, provision.log alongside. .data files
were on the now-terminated instance.)_
