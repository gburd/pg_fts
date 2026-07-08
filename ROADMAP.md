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

4. **Index size and ranked latency — the competitive gap (see
   `bench/NOTE_SIZE_AND_SPEED.md` for the full code-verified analysis).**
   pg_fts trails VectorChord/pg_textsearch on index size (~5.5×) and ranked
   latency (rare-term ~10×, common-term ~20×). The verified root causes — which
   correct the earlier "positions make the index big" narrative (the bm25 index
   stores **no** positions; those live in the heap `ftsdoc`) — and the plan:

   - **P1 — doclen sidecar (highest-leverage, format change).** `doclen` is a
     per-document value but is stored once per posting (once per doc×term pair),
     ~38–45% of the index (`pg_fts_am.c:243,344,909,921`). Move it to a
     per-segment array indexed by docid: ~40% smaller index **and** ~40% less
     common-term decode. Needs `BM25_VERSION` bump + dual-read.
   - **P2/P3 — execution-path fixes (cheap, no format change).** The ranked scan
     reads the metapage 3× and does 3× dict lookups per term, and creates+drops
     a `TupleTableSlot` per candidate while over-fetching `max(k*4,64)`
     (`pg_fts_am_scan.c`). Cache the metapage + dict entry once per scan, reuse
     one slot, and right-size the over-fetch. This is most of the rare/mid-term
     gap (target 15.8 → ~4–6 ms) and helps common terms too.
   - **P4 — impact-quantized postings + hard top-k WeakAND (format change).**
     The only lever that makes common-term latency *flat* like VectorChord.
     Distinct from the reverted impact-*directory* (`NOTE_IMPACT_ORDERING.md`,
     which ordered docid blocks whose bounds clustered too tightly): quantize
     *postings* into impact tiers stored highest-first, so a moving threshold
     genuinely skips low-impact tiers. Sequence after P1.

   Do P2/P3 first (cheap, whole-distribution win), then P1 (size + decode), then
   P4 (flat common-term latency) if that is a must-win.

5. **`WITH (positions=off)` — heap-side only.**
   An option to omit token positions from the heap `ftsdoc` for phrase-free
   workloads: smaller heap column, faster build/insert/merge. It does **not**
   shrink the bm25 index (which stores no positions — see #4); the earlier
   "smaller index" framing was wrong. Phrase/NEAR require positions, so opt-in.

6. **COUNT / aggregation Custom Scan pushdown.**
   A transparent `count(*) WHERE col @@@ query` currently runs as a bitmap heap
   scan, which goes lossy on a huge match set and rechecks the heap.
   `fts_count()` already avoids this with a visibility-map-based bulk count, but
   it is an explicit function call. A `set_rel_pathlist_hook` /
   `create_upper_paths_hook` Custom Scan that pushes COUNT into the index would
   make plain `count(*)` fast without the explicit call.

7. **Parallel scan (`amcanparallel`).**
   Query execution is single-threaded. A parallel bitmap / ordering scan would
   help large scans, and underpins the flat common-term latency described in #4.
   Warm-cache selective queries benefit little, so this targets large or
   common-term workloads.

8. **Storage AIO / `read_stream` prefetch for the cold merge full-scan.**
   The build heap scan already gets core `read_stream` prefetch for free. The
   remaining candidate is the cold merge full-scan of posting pages, *if*
   `BM25SegMeta` recorded a contiguous posting block range so a `blk++`
   read_stream callback could prefetch. Low priority — pointer chains and WAND
   block-skipping defeat prefetch elsewhere. Deferred until a cold-merge I/O
   bottleneck is measured.

## Sparsemap (vendored)

9. **Exercise batch/cached sparsemap APIs under a delete-heavy workload.**
   The batched tombstone filter (`sm_contains_many`) and MRU-cached membership
   test (`sm_contains_cached`) are integrated into the WAND cursor and merge
   paths. They only help the tombstone/merge paths, so a delete-free read
   benchmark shows no effect. TODO: quantify the gain on a delete/update-churn
   workload where they should help.

## Benchmark / competitive

10. **Multi-engine real-corpus comparison — done; iterate.**
   A clean 3-way comparison (build time, index size, per-query latency across
   selectivity bands) vs VectorChord-bm25 and Timescale pg_textsearch on 2.19M
   Wikipedia articles is in `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md`. It shows
   pg_fts trailing on ranked latency and index size (the codec gap, #4) while
   leading on query-language breadth and index-native COUNT. The follow-up is
   the format-v3 codec work (#4), not more benchmarking.

11. **`fts_search` SRF under-fetch safety.**
    The top-k over-fetch is tight (`k*2`). This is safe for the ordering scan
    (which retries), but the `fts_search()` SRF does not retry — under a
    heavy-delete workload where more than half the top rows are invisible it
    could return fewer than `k`. A small internal retry in `bm25_topk_visible`
    (grow the requested count and re-scan when `nvis < k`) would make tight
    over-fetch fully safe everywhere.

## Correctness / robustness (lower urgency)

12. **Sparsemap error-path leaks.**
    `sm_create` / blob buffers are palloc/libc allocations; on an `ereport`
    between create and free they leak for the duration of the statement
    (reclaimed at transaction/backend end). A `PG_TRY`/`PG_FINALLY` around the
    few error-prone spots would tidy this. Low severity — rare error paths only.
