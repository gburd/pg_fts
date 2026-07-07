# pg_fts — roadmap (planned enhancements, not yet implemented)

Enhancements that are designed or prototyped but not yet shipped, tracked so
they are not rediscovered. Ordered roughly by value.

## Performance

1. **Verify parallel merge at scale.**
   Parallel merge (`bm25_merge_all_parallel`) is implemented and verified
   correct locally (parallel build → many segments → parallel `fts_merge` → one
   segment, byte-identical counts). It has not yet been timed on a very large
   (multi-million-document) corpus. When enough parallel worker slots are
   available (`max_worker_processes` set high enough that
   `LaunchParallelWorkers` succeeds), the code takes the parallel path and
   otherwise falls back to a correct serial merge. TODO: capture the
   parallel-merge speedup vs the serial path at scale.

2. **Level-2 recursive parallel merge (W → W/2 → … → 1).**
   The current parallel merge does one parallel pass into (workers+1) segments,
   then a serial final combine to one. For very large indexes that final
   combine is still O(index) single-threaded. Recursing the parallel merge so
   the final combine also parallelizes would remove it. Deferred — one parallel
   pass already removes the dominant per-segment decode cost.

3. **Parallel build: fewer, larger per-worker segments.**
   Each worker currently flushes several segments (budget-triggered), so a
   parallel build leaves many segments needing a merge. Giving each worker a
   larger flush budget (its share of `maintenance_work_mem`) would leave ~1
   segment per worker, shrinking the post-build merge input. Complements #1/#2.

4. **Ranked common-term latency (the headline gap).**
   Ranked top-k over a very common term (docid-ordered block-max WAND) is the
   largest gap vs VectorChord/pg_textsearch
   (`bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md`): block-max WAND cannot skip blocks
   when a term appears in most documents. Profiling shows such a query is
   roughly one-third decode + block-load and two-thirds scoring/heap/executor,
   so an incremental codec tweak is capped and cannot enable additional
   skipping. Two attempts were prototyped and reverted with evidence
   (`bench/NOTE_IMPACT_ORDERING.md`, `bench/NOTE_PARALLEL_RANKED.md`). The real
   lever is a **format-v3 codec**: a compact columnar posting layout
   (rank/select-friendly docid set + quantized-impact sidecar, positions
   optional) with a hard top-k early-termination like VectorChord's block-WeakAND
   — a substantial rewrite, and the only thing shown capable of closing the gap.
   A cheaper adjacent win: an **optional no-positions index mode**
   (`WITH (positions=off)`) for phrase-free workloads — smaller index, faster
   build and scan — keeping phrase/NEAR support opt-in.

5. **COUNT / aggregation Custom Scan pushdown.**
   A transparent `count(*) WHERE col @@@ query` currently runs as a bitmap heap
   scan, which goes lossy on a huge match set and rechecks the heap.
   `fts_count()` already avoids this with a visibility-map-based bulk count, but
   it is an explicit function call. A `set_rel_pathlist_hook` /
   `create_upper_paths_hook` Custom Scan that pushes COUNT into the index would
   make plain `count(*)` fast without the explicit call.

6. **Parallel scan (`amcanparallel`).**
   Query execution is single-threaded. A parallel bitmap / ordering scan would
   help large scans, and underpins the flat common-term latency described in #4.
   Warm-cache selective queries benefit little, so this targets large or
   common-term workloads.

7. **Storage AIO / `read_stream` prefetch for the cold merge full-scan.**
   The build heap scan already gets core `read_stream` prefetch for free. The
   remaining candidate is the cold merge full-scan of posting pages, *if*
   `BM25SegMeta` recorded a contiguous posting block range so a `blk++`
   read_stream callback could prefetch. Low priority — pointer chains and WAND
   block-skipping defeat prefetch elsewhere. Deferred until a cold-merge I/O
   bottleneck is measured.

## Sparsemap (vendored)

8. **Exercise batch/cached sparsemap APIs under a delete-heavy workload.**
   The batched tombstone filter (`sm_contains_many`) and MRU-cached membership
   test (`sm_contains_cached`) are integrated into the WAND cursor and merge
   paths. They only help the tombstone/merge paths, so a delete-free read
   benchmark shows no effect. TODO: quantify the gain on a delete/update-churn
   workload where they should help.

## Benchmark / competitive

9. **Multi-engine real-corpus comparison — done; iterate.**
   A clean 3-way comparison (build time, index size, per-query latency across
   selectivity bands) vs VectorChord-bm25 and Timescale pg_textsearch on 2.19M
   Wikipedia articles is in `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md`. It shows
   pg_fts trailing on ranked latency and index size (the codec gap, #4) while
   leading on query-language breadth and index-native COUNT. The follow-up is
   the format-v3 codec work (#4), not more benchmarking.

10. **`fts_search` SRF under-fetch safety.**
    The top-k over-fetch is tight (`k*2`). This is safe for the ordering scan
    (which retries), but the `fts_search()` SRF does not retry — under a
    heavy-delete workload where more than half the top rows are invisible it
    could return fewer than `k`. A small internal retry in `bm25_topk_visible`
    (grow the requested count and re-scan when `nvis < k`) would make tight
    over-fetch fully safe everywhere.

## Correctness / robustness (lower urgency)

11. **Sparsemap error-path leaks.**
    `sm_create` / blob buffers are palloc/libc allocations; on an `ereport`
    between create and free they leak for the duration of the statement
    (reclaimed at transaction/backend end). A `PG_TRY`/`PG_FINALLY` around the
    few error-prone spots would tidy this. Low severity — rare error paths only.
