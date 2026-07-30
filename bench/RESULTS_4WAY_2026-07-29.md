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

pg_fts row is the RE-RUN on 1.2.2 (2026-07-30, same r6id.4xlarge / local-NVMe /
2.19M-Wikipedia harness), correcting the two methodology/tooling issues that
invalidated the first pg_fts attempt (compact with `fts_vacuum` not `fts_merge`;
query in the `WHERE @@@ ... ORDER BY <=>` form).  Competitor rows unchanged from
the 2026-07-29 run.

| engine | index size (compacted) | build | rare k10 | mid k10 | common k10 | common k100 | count(*) common |
|---|---:|---:|---:|---:|---:|---:|---:|
| **VectorChord-bm25** | **1449 MB** | **48 s** (+~13 min tsvector prep) | 16.9 ms | 15.3 ms | 15.3 ms | 45.4 ms | n/a (ranking-only) |
| **Timescale pg_textsearch** | 1869 MB | 231 s | 13.3 ms | 13.9 ms | 38.0 ms | 46.8 ms | n/a (ranking-only) |
| **ParadeDB pg_search** | 2321 MB | 62 s | 14.0 ms | 13.6 ms | **13.8 ms** | **18.5 ms** | 96.0 ms |
| **pg_fts 1.2.2 (stored col)** | **4239 MB** | 57 s + 231 s `fts_vacuum` (+~16 min stored-col materialize) | **8.5 ms** | **4.6 ms** | 31.8 ms | 32.9 ms | 756 ms |
| **pg_fts 1.2.2 (expr index)** | 4239 MB | 163 s + 232 s `fts_vacuum` | 19.2 ms | 4.8 ms | 43.9 ms | 77.9 ms | (same count path) |

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
- **pg_fts 1.2.2**: index floor **4239 MB** — matches the historical 4188 MB
  (0.3.5, pos=off); NO size regression (the first run's "15 GB" was compacting
  with the extend-only `fts_merge` instead of the reclaiming `fts_vacuum`, plus
  a 1.2.1 `fts_vacuum` bug now fixed in 1.2.2). ~1.9–2.9× the two smallest
  competitors, in line with history. RANKED LATENCY is competitive and even
  leads on rare/mid: rare 8.5 ms and mid 4.6 ms (stored-col form) are the
  fastest in the table; common-term is 32 ms (behind pg_search's 14 ms — the
  known impact-ordered-codec gap). The stored-vs-expr delta (rare 8.5 vs 19.2,
  k100 33 vs 78) is exactly the per-row re-analysis tax the methodology warns
  about — report the stored-col form as the app-representative number.
- **pg_fts weak spot, now measured:** `count(*)` on a common term is **756 ms**
  (df ~735k) — the index-native count walks all matches; a real latency gap vs
  everything else and a concrete optimization target. Mid-term count is 5 ms, so
  it is specifically the very-high-df count that is slow.

## pg_fts anomalies (findings — NOW RESOLVED; pg_fts row above is the re-run)

**RESOLVED after root-cause and a full re-run on 1.2.2** (the pg_fts rows in the
results table above are the corrected numbers: 4239 MB floor, ranked 4.6–8.5 ms
rare/mid).  The two issues below were diagnosed and one was a real bug, now fixed:

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

## Honest read (updated after the pg_fts 1.2.2 re-run)
- **pg_search** is the common-term ranked-latency + capability leader (flat
  ~14 ms across bands, richest queries); **VectorChord** the size/build-speed
  leader (ranking-only); **pg_textsearch** the compact native-C middle.
- **pg_fts 1.2.2** is competitive, not the outlier the first run implied:
  - **Size:** 4239 MB floor after `fts_vacuum` — matches history (4188 MB), no
    regression. ~1.9–2.9× the smallest competitors (the known size gap; the
    doclen-sidecar ROADMAP lever still applies).
  - **Ranked latency:** LEADS on rare (8.5 ms) and mid (4.6 ms) in the
    stored-column form — fastest in the table; TRAILS on common-term (32 ms vs
    pg_search 14 ms), the impact-ordered-codec gap.
  - **Capability:** still the only one with index-native count(*), phrase,
    boolean, prefix/fuzzy/regex over one operator — but common-term count(*) is
    **756 ms** (df ~735k), a real weak spot and a concrete optimization target.
  - **Correctness/robustness:** the 1.2.x concurrency + build + fts_vacuum fixes
    (ASan-clean concurrent read+insert+merge+vacuum) are a genuine
    differentiator the competitors were not tested on here.

## Not yet measured (dims 4/7/8 — the new axes)
Ranked QPS under concurrency (dim 4), concurrent write+query correctness (dim 7,
where 1.2.x should shine and competitors may not even run cleanly), and NDCG/P@k
recall (dim 8) were NOT reached — the pg_fts size/scan issues consumed the
window. Sequence them after fixing the size regression, since a 15 GB index
distorts every pg_fts number.
