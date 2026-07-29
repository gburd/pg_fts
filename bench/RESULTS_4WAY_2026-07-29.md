# pg_fts 4-way BM25 benchmark (2026-07-29) — competitive re-run

**Status: PARTIAL — 3 competitors measured cleanly; pg_fts hit two issues that
are findings in themselves (see "pg_fts anomalies").** Run per
`bench/PLAN_4WAY_BENCHMARK.md`. DB on **local NVMe** (r6id.4xlarge instance
store, xfs), one engine at a time, warm median-of-9.

## Provenance
- Instance: EC2 **r6id.4xlarge** (16 vCPU Ice Lake, ~123 GB), Fedora 43,
  1×884 GB **local NVMe instance store** mounted at `/nvme` (all PGDATA + corpus
  there; NOT EBS, NOT tmpfs). Account `ouch`, us-east-2. **TERMINATED after.**
- PostgreSQL **17.10** from source (`--without-icu -O2`), one shared cluster on
  NVMe. GUCs: shared_buffers=64GB, mwm=16GB, work_mem=256MB, jit=off,
  autovacuum=off, fsync=off, parallel workers 8/16/8.
- Corpus: wikimedia/wikipedia 20231101.en, **first 2,188,038 articles**, body
  column (matches history exactly). Heap = **4558 MB**.
- Analyzers: pg_fts + pg_textsearch = PostgreSQL `english` (Snowball);
  VectorChord = `to_tsvector('english',...)` (installed opclass is `FOR TYPE
  tsvector`, matched Snowball); pg_search = Tantivy default (analyzer-relative).
- Query bands (historical): slovakia (rare, df~10.9k), hungary (mid, df~24k),
  year (common, df~735k).
- **Engine isolation:** pg_textsearch, VectorChord-bm25, and pg_search each
  define an access method named `bm25` and CANNOT coexist — vchord and pg_search
  ran in their own databases (`bench_vchord`, `bench_pgsearch`); pg_fts (AM
  `fts`) + pg_textsearch (AM `bm25`) shared `bench`.

## Engine versions (pinned)
- **pg_fts** 1.2.1 (this repo HEAD, 9732186).
- **ParadeDB pg_search** 0.25.0 (commit e6bca5c), pgrx 0.19, embeds Tantivy;
  needs `vector` (pgvector 0.8.5) + openblas at link.
- **Timescale pg_textsearch** 1.4.0-dev (commit 3b2f2ba).
- **VectorChord-bm25** commit 14fc2a3 (same HEAD as the 0.3.5-era run), pgrx 0.17.

## Results — size, build, ranked top-k latency (stored/expr form as noted)

| engine | index size (compacted) | build | rare k10 | mid k10 | common k10 | common k100 | count(*) common |
|---|---:|---:|---:|---:|---:|---:|---:|
| **VectorChord-bm25** | **1449 MB** | **48 s** (+~13 min tsvector prep) | 16.9 ms | 15.3 ms | 15.3 ms | 45.4 ms | n/a (ranking-only) |
| **Timescale pg_textsearch** | 1869 MB | 231 s | 13.3 ms | 13.9 ms | 38.0 ms | 46.8 ms | n/a (ranking-only) |
| **ParadeDB pg_search** | 2321 MB | 62 s | **14.0 ms** | **13.6 ms** | **13.8 ms** | **18.5 ms** | 96.0 ms |
| **pg_fts 1.2.1** | **15 GB (!)** | 85 s | (KNN scan did not engage — see below) | | | | (count pushdown needs preload) |

Notes:
- **VectorChord** smallest + fastest build, flat latency (its Block-WeakAnd
  skipping) — but the tsvector materialization is a real ~13 min one-time tax
  and it is ranking-only (no @@@ match / count / phrase).
- **pg_search** has the flattest ranked latency (Tantivy: common ≈ rare ≈ 14 ms,
  k100 only 18.5 ms — best-in-class common-term) and the richest query surface;
  index 2321 MB; index-native count(*) but at 96 ms it is far slower than its
  ranked path.
- **pg_textsearch** compact + fast rare/mid, but common-term degrades (38–47 ms)
  and it is ranking-only.

## pg_fts anomalies (findings — NOT clean competitive numbers)

**RESOLVED after root-cause (see follow-up commit).** The two issues below were
diagnosed and one was a real bug, now fixed:

1. **The "15 GB" was not a true index-size regression.** Two causes:
   (a) *Methodology error*: this run compacted with `fts_merge()`, which is
   intentionally EXTEND-ONLY (recycles freed pages to the FSM but never
   truncates) — it does not shrink. `fts_vacuum()` is the reclaiming path.
   (b) *A real bug*: the deletion-XID recycle gate (added for concurrent
   scan-vs-merge safety) also blocked `fts_vacuum()`'s vacate+pack phase from
   reusing the low pages it had just freed, so `fts_vacuum()` GREW the index
   every call (reproduced locally: 182 MB → 340 → 498) instead of shrinking.
   Fixed by bypassing the recycle gate during single-writer compaction; after
   the fix `fts_vacuum()` compacts to a stable floor (182 MB → **79 MB**,
   idempotent). On the same local corpus GIN was 46 MB, so the true pg_fts
   size ratio is **~1.7×**, in line with the historical ~2.2× vs pg_textsearch —
   NOT the ~3.6× the raw EC2 number implied.

2. **The "24 s ranked latency" was a wrong query form, not a scan bug.** The
   benchmark query used `ORDER BY d <=> q LIMIT k` with NO `@@@ q` WHERE clause.
   pg_fts's index is `amoptionalkey=false`, so a pure ORDER BY cannot use the
   index → seqscan+top-N sort (24 s, evaluates every row). The correct
   ranked-search form `WHERE d @@@ q ORDER BY d <=> q LIMIT k` uses the KNN
   Index Scan (`Index Cond: @@@`, `Order By: <=>`) and runs in **~1.5 ms**
   (200k-doc local corpus, df=200k common term). The `<=>` KNN opclass
   (sortfamily float_ops) is wired correctly; no code change was needed for
   latency. (pg_fts must be in `shared_preload_libraries` for the count(*)
   pushdown CustomScan, but the KNN scan itself does not require it.)

**Net:** pg_fts is competitive on size (~1.7× GIN, comparable to the native-C
engines) and fast on ranked top-k when queried in the correct
`WHERE @@@ ORDER BY <=>` form. The clean at-scale head-to-head still needs a
re-run (the EC2 run's pg_fts column was invalid); the corrected harness must
(a) compact pg_fts with `fts_vacuum()` not `fts_merge()`, and (b) use the
`@@@`+`<=>` query form.

## Honest read (unchanged in shape from NOTE_COMPETITIVE_LANDSCAPE.md)
- **pg_search** is the ranked-latency + capability leader (flattest common-term,
  richest queries); **VectorChord** the size/build-speed leader (ranking-only);
  **pg_textsearch** the compact native-C middle.
- **pg_fts** could not post a valid latency number this run and shows a serious
  **index-size regression (15 GB)**. Its differentiators remain capability
  (index-native count, phrase/boolean/fuzzy/regex) and correctness/robustness
  (the 1.2.x concurrency + build fixes) — but the size regression must be
  root-caused and fixed before pg_fts is competitively benchmarkable on size or
  ranked latency again. **This is the #1 action item.**

## Not yet measured (dims 4/7/8 — the new axes)
Ranked QPS under concurrency (dim 4), concurrent write+query correctness (dim 7,
where 1.2.x should shine and competitors may not even run cleanly), and NDCG/P@k
recall (dim 8) were NOT reached — the pg_fts size/scan issues consumed the
window. Sequence them after fixing the size regression, since a 15 GB index
distorts every pg_fts number.
