# pg_fts 5-way BM25 competitive benchmark plan (2026-08, statistically valid, under load)

Directive: benchmark pg_fts vs ALL competitors in the BM25 full-text index space,
at scale, UNDER LOAD, statistically valid, on EC2 local-NVMe storage, using
MULTIPLE EC2 instances in parallel, across ALL features.

## Engines (one dedicated EC2 instance each, in parallel)

| engine | AM | analyzer | notes |
|---|---|---|---|
| pg_fts 1.4.0 | fts | english (Snowball) | this repo, tag v1.4.0 |
| Timescale pg_textsearch | bm25 | english | C, ranking-only |
| ParadeDB pg_search (Tantivy) | bm25/paradedb | Tantivy default | Rust; needs pgvector+openblas |
| VectorChord-bm25 | bm25 | to_tsvector english | Rust; ranking-only, tsvector-based |
| built-in tsvector + GIN + ts_rank_cd | gin | english | the PostgreSQL baseline |

Each engine on its OWN r6id.4xlarge (16 vCPU Ice Lake, 128 GB, 1x884GB local
NVMe instance store, xfs at /nvme; NOT EBS/tmpfs). PG 17.10 from source
(--without-icu -O2). Same GUCs. Account chiuso, us-east-2, owner=gburd-agent,
/32 SG, terminate+verify after. NEVER touch solnix-*.

## Corpus (identical on every instance)

wikimedia/wikipedia 20231101.en, first 2,188,038 articles, body column (matches
history: heap ~4558 MB). Query bands by document frequency:
  rare  = slovakia (df ~10.9k)
  mid   = hungary  (df ~24k)
  common= year     (df ~735k)
  AND   = slovakia & hungary (co-occurrence)
Plus feature probes (phrase, prefix, fuzzy, regex, field-zone) where supported.

## Feature matrix (measured where the engine supports it; marked n/a otherwise)

ranked top-k (<=> / <@> / ORDER BY score) k=10 and k=100; index-native count(*);
boolean AND; phrase "a b"; prefix a*; fuzzy a~1; regex /re/; field-zone term:A.
Also: build time, index size (compacted), incremental-insert, tombstone/vacuum.

## Statistical validity

For EACH (engine, query-band, k):
1. Warm the cache (run the query set once).
2. LATENCY DISTRIBUTION: N>=200 single-stream timed runs (\timing), report
   median, p95, p99, IQR, and a bootstrap 95% CI on the median. Enough samples
   that the CI is tight.
3. UNDER LOAD: pgbench with a custom script (the query band), fixed clients
   (C=1,8,16,32), fixed duration (60s each), report throughput (TPS) and
   pgbench's own latency avg + the -r per-statement latency; p95/p99 from
   --latency. This is the concurrent-load number.
Correctness cross-check: each engine's top-k / count vs a brute-force seqscan
ground truth on the SAME corpus, so a "fast" engine that is wrong is flagged.

## Orchestration

launch 5 instances in parallel -> provision (NVMe + PG + engine + corpus) in
parallel -> each runs its own bench script writing /tmp/bench_<engine>.json ->
collect all -> assemble the comparison + analysis -> terminate all + verify.

## Deliverable

bench/RESULTS_5WAY_LOADED_2026-08.md: the feature matrix, the latency-distribution
table (median + p95/p99 + CI), the under-load throughput table (TPS + p99 by
client count), build/size, correctness cross-check, and an honest analysis of
where each engine wins/loses and why.
