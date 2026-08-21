# pg_fts — roadmap (planned enhancements, not yet implemented)

Enhancements that are designed or prototyped but not yet shipped, tracked so
they are not rediscovered. Ordered roughly by value.

## Performance

0. **Parallel-build segment-count control (addressed via `pg_fts.build_mem_ceiling_mb`; in-scan compaction still open).**
   The leveled bounded-fan-in merge landed in 1.1.3 and was hardened in 1.1.4
   (content-based commit guard; extend-only merge output -- the SIGBUS fix).  A
   parallel build's workers only flush (they do not merge in-scan), so on a
   corpus that flushes very many segments the directory could climb toward
   `BM25_MAX_SEGMENTS` (128).  1.1.5 addresses this the throughput-safe way with
   the `pg_fts.build_mem_ceiling_mb` GUC: raising it lets each participant flush
   fewer, larger segments so the count stays well under the cap, without any
   in-scan merge (which, tried as a per-flush merge serialized on the relation-
   extension lock, bounded the count but collapsed scan throughput -- rejected).
   A truly automatic rate-limited in-scan compaction (merge a bounded amount per
   trigger without a scan-stalling lock) remains open as a nice-to-have; the GUC
   plus the O(N) validate fix (1.1.5) mean a large CIC build now completes
   without it.  Reference: aether `src/lsm/hanoi.rs` `compute_work_budget` for
   the rate-limited-compaction shape.

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
   `bench/RESULTS_VS_CURRENT.md` for the current 0.3.5 3-way; `bench/NOTE_SIZE_AND_SPEED.md`
   for the code-verified root-cause analysis).**
   As of **0.3.5** (2.19M Wikipedia, r7i.4xlarge, matched Snowball analyzer):
   pg_fts trails VectorChord/pg_textsearch on index size (**~2.9×** vs
   VectorChord, ~2.2× vs pg_textsearch, pos=off) and ranked top-10 latency
   (**~2–6×** vs VectorChord, ~3–5× vs pg_textsearch). **Caveat (profiled
   2026-07-14, `bench/PROFILE_STEP0.md`):** 40–88% of that measured ranked
   latency is `to_ftsdoc('english', body)` *re-analysis* in the executor's
   ORDER BY — the whole article body re-tokenized + Snowball-stemmed per returned
   row — because the benchmark uses an *expression* index (`ORDER BY
   to_ftsdoc(body) <=> q`). That tax is **outside pg_fts's index scan** and a real
   application using a *stored* `ftsdoc` column (`ORDER BY col <=> q`) would not
   pay it. The true index-scan latency gap is smaller than the headline; the
   exec micro-opts (metapage/dict/slot caching) are all below the perf floor at
   2.19M and were correctly NOT implemented.
   narrower than the historical (pg_fts 1.20) ~5.5× size / ~10–20× latency gap:
   making positions **opt-in** (`WITH positions=on`) roughly halved the default
   index (7541→**4188 MB**) with no codec change, and lazy-boolean-eval + scan
   tuning cut ranked latency ~20–25% per band (rare 15.8→12.3, common 39.9→32.1 ms).
   Ranked latency remains the weak axis (still decode-bound), and pg_fts keeps
   its capability edge (index-native `count(*)`, positional phrase, and the
   boolean/NEAR/prefix/fuzzy/regex query language — all competitor-N/A). The
   verified root causes — which correct the earlier "positions make the index
   big" narrative (the bm25 index stores **no** positions by default; those live
   in the heap `ftsdoc` or the opt-in positions column) — and the plan:

   Two rough edges the 0.3.5 re-run surfaced:
   - **`fts_vacuum` convergence + scale** (§5.1): RESOLVED. The oscillation is
     fixed (two-phase compaction converges to the floor, never grows past the
     pre-call size, is interruptible), and the multi-GB scale cost is fixed too:
     a pre-pass guard (`bm25_index_is_compacted`) skips the vacate+pack rewrite
     when the index is already front-packed and single-segment, so a bloated
     index converges in ONE pass and an already-compact index is a near-no-op.
     EC2-validated (bench/RESULTS_VACUUM_SCALE.md): first vacuum 91s->37s on an
     780MB bloat, repeat vacuum 91s->3ms, identical reclaim, parity exact,
     cancel mid-rewrite ~1s. The one remaining non-interruptible step is a
     SINGLE `RelationTruncate` (PostgreSQL's O(NBuffers) `DropRelationBuffers`
     sweep, shared by all relation truncation) -- bounded (seconds), paid once.
   - **The `FtsCount` CustomScan pushdown** is now priced as the index-only
     visibility-map count it performs, so the planner chooses it at scale
     (FIXED, commit in the 1.0 prep series).

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

12b. **Reserved query keywords cannot be searched as literal words.**
    The query lexer recognizes `and`/`or`/`not`/`near` as operators
    unconditionally, so `to_ftsquery('english','and & x')` errors and even a
    phrase `"and"` fails (`pg_fts_query.c` keyword recognition runs before
    phrase-term handling).  Standard `to_tsquery` treats a bare `and` as a
    lexeme (then drops it as a stopword).  A fix would suppress keyword
    recognition inside a phrase/NEAR operand context (a `lex_terms_as_words`
    flag threaded into the lexer).  Low urgency: on natural-language corpora
    these words are stopwords and are dropped anyway (v1.3.1 stopword fix), so
    the only loss is searching for the literal token in a non-stopword config.
    Reported alongside the stopword-asymmetry bug (fixed in 1.3.1) as a distinct,
    minor issue.

12. **Sparsemap error-path leaks.**
    `sm_create` / blob buffers are palloc/libc allocations; on an `ereport`
    between create and free they leak for the duration of the statement
    (reclaimed at transaction/backend end). A `PG_TRY`/`PG_FINALLY` around the
    few error-prone spots would tidy this. Low severity — rare error paths only.

## Managed-service readiness (RDS / Aurora PostgreSQL candidacy)

Work to take pg_fts from "correct open-source extension" to "candidate for a
managed PostgreSQL service" (customers with no OS/superuser access, always-on
read replicas, possibly compute/storage-separated backends). The hard
architectural bar is already
cleared: 100% GenericXLog page logging, atomic metapage publish points, standby-
safe XID-gated page recycling, cancellation in every long loop. What remains is
privilege hygiene, two small write-path guards, one statistics fix, and
validation under always-on-replica conditions. Keep `trusted = true`.

### P0 — correctness / safety blockers (each small; all confirmed present in HEAD)

13. **[DONE 1.3.0] Guard `fts_merge` / `fts_vacuum` against running during recovery.**
    Both (`pg_fts_am.c` ~4787 / ~4832) open the index and take heavy locks
    (`fts_vacuum` takes `AccessExclusiveLock`) with NO recovery check, so on a
    hot standby they start work and then fail hard at the first WAL write during
    recovery. Reachable in normal use (replicas always present; both are plain
    SQL functions any session can call). Fix: at the very top of each, before
    `index_open`, `if (RecoveryInProgress()) ereport(ERROR, errcode
    ERRCODE_READ_ONLY_SQL_TRANSACTION, "... cannot run during recovery")`. The
    AM callbacks (`aminsert`/`ambulkdelete`/`ambuild`/`amvacuumcleanup`) do NOT
    need it (core never invokes them during recovery). Add a TAP assertion on
    the existing streaming-replication standby that both error on the replica.

14. **[DONE 1.3.0] Lock down the function privilege surface.** Install SQL has 0 REVOKE/GRANT
    (`pg_fts--*.sql`); all 33 functions are `PUBLIC`-executable and none does an
    ownership/ACL check. Two parts:
    - *Maintenance* (`fts_merge`, `fts_vacuum`): a caller supplying any index OID
      can trigger a costly compaction or an `AccessExclusiveLock` stall on an
      index they do not own. Add an ownership check (e.g. `object_ownercheck` /
      `pg_class_aclcheck` on the index or underlying table) so only the owner (or
      an admin) can run them.
    - *Content-exposing introspection* (`fts_search`, `fts_anomalous_docs` emit
      indexed heap TIDs / scores / term text; `fts_index_stats` / `fts_index_df`
      / `fts_count` to a lesser degree): exposing to `PUBLIC` widens content
      visibility past table-level permissions. Decide the model and make it
      explicit in install SQL with `REVOKE ... FROM PUBLIC` + deliberate grants;
      at minimum gate the two functions that emit indexed content to the table
      owner. NOTE: needs a design decision + a `pg_fts--1.2.2--1.3.0.sql`
      upgrade that applies the same REVOKE/GRANT to existing installs (not a
      no-op upgrade). Keep all install/upgrade SQL pure ASCII (`make
      check-ascii`).

15. **[DONE 1.3.0] Do not count recently-dead tuples into corpus statistics.**
    `bm25_build_callback` (`pg_fts_am.c` ~578) ignores `tupleIsAlive`: it always
    does `bs->ndocs += 1.0` and `bs->sumdoclen += doc->doclen` AND indexes the
    posting. During CREATE INDEX/REINDEX/VACUUM FULL, recently-dead tuples arrive
    with `tupleIsAlive = false` (routine whenever any snapshot pins the horizon —
    e.g. replica feedback). They MUST still be indexed (an old snapshot may need
    them) but MUST NOT count toward `ndocs`/`sumdoclen` (BM25 IDF + length
    normalization), else scoring is biased and the reported doc count over-
    reports. Fix: keep the `add_posting` loop; gate ONLY the two stat increments
    on `tupleIsAlive`. Verify no other build path (parallel worker callback,
    merge stat accumulation) double-counts. Regression: build with a second
    session holding a `REPEATABLE READ` snapshot over deleted-but-unvacuumed rows
    and assert `fts_index_stats` doc count excludes them while a query still finds
    them from the old snapshot.

### P1 — validation under managed-service conditions

16. **[DONE: deterministic delete+VACUUM+REINDEX ndocs in the SQL suite + hardcoded-size test audit; concurrent-session TAP deferred (async-psql harness flaky on CI host)] Horizon-pinned-by-a-reader regression scenario.** A second session holding
    a `REPEATABLE READ` snapshot defers dead-tuple reclaim + physical shrink and
    changes which tuples reach the build callback. Add coverage that pins the
    horizon then exercises build, delete+VACUUM, and `fts_vacuum()`, asserting
    *properties* (results correct, statistics eventually correct, index never
    grows unbounded) NOT exact sizes/block numbers. Audit existing tests for any
    hardcoded physical size / block number that would flake under a pinned
    horizon and rewrite to assert the property (the `vac` reclaim block already
    uses ratio assertions — extend that discipline).

17. **[PARTIAL: failover TAP scenario (promote standby, index correct + writable) landed on stock PG; actual Aurora-style compute/storage-separated backend validation remains EXTERNAL] Full validation pass on a compute/storage-separated backend.** GenericXLog-
    everywhere should port cleanly, but validate from scratch on the target
    platform: crash/kill recovery, replica replay equivalence, failover, and a
    full `make installcheck` + TAP. Extend the existing crash-recovery + streaming-
    replication TAP tests to the target and add a failover scenario. (Bench/soak
    on EC2, never on LAN hosts.)

18. **[DONE: consolidated "Operating pg_fts" operator runbook -- auto-maintenance, fts_merge vs fts_vacuum, transient space, replica behavior, privileges, ingestion] Operator documentation.** A concise operator-facing summary: what triggers
    auto-merge vs auto-vacuum; when to call `fts_merge()` vs `fts_vacuum()`; the
    transient extra space a compaction needs (rewrites live data before freeing
    the old copy, like a table rewrite); replica behavior (reads work, maintenance
    functions error — after #13); behavior under continuous ingestion (segment
    count, write amplification). Much exists in README/design notes; distill it.

### P2 — process / hardening

19. **[PARTIAL: per-release storage/WAL/crash-recovery review checklist in RELEASING.md; an EXTERNAL human review remains a release-integrator step] Independent review of the WAL / crash / recovery / storage paths.** Single-
    author project; a service integrator wants a second set of eyes. Even a
    documented per-release review checklist for the AM + recovery code de-risks
    adoption. (Pairs with the worker->reviewer subagent discipline already used
    for traversal/concurrency-core changes.)

20. **[DONE: PG_FTS_TEST_HOOKS in NO build recipe + _PG_init WARNINGs loudly if a test-hook build loads] Make the test-only hook impossible to ship.** The one test-only GUC
    (`PG_FTS_TEST_HOOKS` / `pg_fts_test_pause_advisory_key`) is compile-gated.
    Confirm production build recipes (Makefile, meson, flake, PGXG/PGDG packaging)
    never define the macro, and consider a build-time assert of its absence in
    the release build.

21. **[DONE: fuzz gate ALL CLEAN, planted-bug teeth abort as expected] Keep the "bounded miss, never crash" contract explicit + CI-guarded.**
    The decoder bounds-checks page-derived lengths and validates pending-page
    documents before trusting offsets, so a torn/stale page degrades to a bounded
    wrong-count, not a crash — the right contract for a service. Keep the
    fuzz/property tests that guard it in CI and treat any regression as release-
    blocking.

### Suggested order

#13, #14, #15 (P0; each a few focused hours) remove the only hard blockers ->
#16 horizon-pinned regressions + test audit -> #17 target-backend validation ->
#18 operator docs -> #19-#21 review + hardening. #13 and #15 are C-only, no-op
upgrade SQL; #14 needs a real REVOKE/GRANT upgrade script + a privilege-model
decision.
