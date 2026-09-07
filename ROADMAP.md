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

   - **P1 — doclen sidecar (DONE, shipped in 1.5.0, format v3->v4).** `doclen`
     was stored once per posting (once per doc x term); moved to a per-segment
     sidecar of one quantized byte per doc (Lucene/Tantivy fieldnorm).  Measured
     at 2M: index 40% smaller, common-term ranked top-10 7.7x faster (17.5->2.3
     ms), top-100 5.6x faster.  Dual-reads v3 (inline) + v4 (sidecar); no REINDEX;
     segments migrate on merge/vacuum.  `avgdl` stays exact; ordering changes at
     most ~0.2% at tie boundaries.  (Also delivered most of the P4 common-term
     latency win early -- the block is ~56% smaller and scoring is a byte lookup.)
   - **P2/P3 — execution-path fixes (evaluated, NO-OP on current code).** The
     rare/mid gap the ROADMAP targeted (15.8 -> 4-6 ms) was already realized in
     the 1.0.x-1.2.x line (rare/mid are 1.9/1.7 ms).  An A/B of the over-fetch
     (k*4 -> k*2) and metapage caching moved nothing measurable; not shipped.
     See bench/PLAN_STORAGE_PERF_2026-08.md and bench/phases/.
   - **P4 — impact-quantized postings (NOT PURSUED; premise resolved by P1).**
     Was scoped as the lever to make common-term latency flat.  After the P1
     doclen sidecar shipped (1.5.0), common-term ranked is 2.3 ms warm (was 28
     ms) and touches 30x fewer index buffers -- at/below every competitor's own
     common-term number.  The impact-*directory* variant was already proven not
     to prune real text (`NOTE_IMPACT_ORDERING.md`), and P4's decode-cost win is
     now largely captured by v4's ~56%-smaller blocks.  Deferred unless a field
     report shows a common-term need v4 does not meet.  See
     bench/PLAN_STORAGE_PERF_2026-08.md + bench/phases/.

   Storage/perf plan OUTCOME: P1 (doclen sidecar, 1.5.0) delivered BOTH the size
   win (40% smaller) and the common-term latency win (7.7x warm) that P1+P4 were
   scoped to achieve together.  P2/P3 were a measured no-op (already banked in
   1.0.x-1.2.x).  Plan complete.

4a. **Common-term ranked top-k -- PROFILED 2026-09-06; premise was wrong, no
   format decision needed yet** (`bench/NOTE_PROFILE_COMMON_TERM_2026-09-06.md`).
   This item previously asserted "the cost IS the posting scan" and framed the
   next step as a size-vs-latency trade (impact-ordered postings vs our
   best-in-field 1421 MB index).  **`perf` on EC2 refuted that.**
   - 24% of common-term latency was `bm25_doclen_cursor_lookup()`'s binary
     search -- ~7 branchy iterations per posting on a term whose docids are
     consecutive.  An **ascending-resume hint** (~8 lines, no format change, no
     exactness loss) took common k10 **56.3 -> 42.67 ms (1.32x)** and k100
     **69.78 -> 54.09 (1.29x)**, parity PASS 10/10.  Shipped.
   - Instrumented counts then showed the bands invert: post-fix `year`'s doclen
     path is **optimal** (15,220 block loads for ~17,094 blocks, 95.5% hint
     hits), while **rare/mid decode a 128-entry block to serve ~1.8-2.2 lookups
     = 71x / 59x amplification** (`perf` on `slovakia`: 61% in
     `load_page`).  That is a different inefficiency from the one 1.5.9 fixed.
   - A lazy per-entry decode to exploit it was tried and **REJECTED by
     measurement** (rare 5.85 -> 8.72 ms): `bm25_for_get()` tests one bit at a
     time, so per-entry access is >10x costlier than the vectorizable batch
     `bm25_for_unpack()`, losing even at 2 entries of 128.
   **Round 2 (same day, measured):** the partial-unpack lever was built and
   **DISPROVEN**, and it corrected the "71x amplification" figure that motivated
   it.  The sidecar is keyed by ALL docids, so a rare term's target sits at an
   arbitrary offset in its 128-entry block -- measured **avg 82.4 entries decoded
   per block**, not 2.  Those entries are the unavoidable gap-decode prefix
   (docids are delta-encoded, so no random access), not waste.  Forcing a small
   window made it worse (rare 5.83 -> 7.74 ms) via ~15k geometric rewalks.
   What DID land in round 2: **`bm25_for_get()` was still decoding bit-by-bit**
   while the batch `bm25_for_unpack()` had long since been optimized to
   word-load/shift/mask.  It is read per-posting for `tf` in `wand_contrib_cur()`.
   Giving it the same extraction took common k10 **42.67 -> 36.16 ms** and k100
   **54.09 -> 46.01**, rare/mid/OR flat, parity PASS 10/10, fuzz clean.
   **rare/mid are now near their floor** -- what remains in `load_page` is the
   gap-decode prefix, inherent to delta-encoded docids.  Moving them further needs
   a FORMAT change (periodic absolute docids within a block, to allow a mid-block
   start) worth at most ~2x of a portion of the query.  Not attempted; likely not
   worth it.
   The WAND ceiling from `bench/NOTE_WAND_PRUNING_2026-09-04.md` still stands and
   is unchanged (bound tight, threshold healthy, flat impact plateau => nothing to
   skip; three easy fixes disproven).  What that note never established -- and
   what this item wrongly asserted on top of it -- is that the remaining time was
   irreducible.  Standing gap: common k10 42.67 ms vs pg_search 2.12 / vchord
   3.49 / pg_textsearch 20.71.
   **Only if the batch-partial-unpack lever is exhausted** does the real
   trade-off arrive: impact-ordered/tiered postings are the Lucene/Tantivy fix but
   break the docid ordering `count(*)`/AND/phrase/prefix rely on
   (`bench/NOTE_IMPACT_ORDERING.md`), implying a second posting layout per term
   and spending our size lead; early termination is cheaper but breaks exact
   top-k, which parity_check enforces.  Do not open that decision on an
   unprofiled premise again.

4b. **Phrase queries — PROFILED 2026-09-06; the win was documentation, not code**
   (`bench/NOTE_PHRASE_PROFILE_2026-09-06.md`).
   Two findings.  First, **our published "phrase 90.70 ms" was not a phrase**: it
   was written with single quotes, which parse to `('unit' & 'state')` -- a plain
   AND.  Phrase needs DOUBLE quotes.  RESULTS_5WAY_159b carries an in-place
   correction.
   Second, the real numbers (2.19M docs, `"united states"`, 361,465 matches):
   ranked top-10 **8,385 ms** with the default `positions=off` vs **229 ms** with
   `positions=on` (**36x**); exact phrase `count(*)` **7,170 -> 132 ms** (**54x**);
   index 1421 -> 2626 MB (1.85x).  With positions off a phrase cannot be verified
   from the index, so the scan falls back to AND + a HEAP RECHECK per candidate.
   **Shipped: the documentation gap.**  README and `doc/pg_fts.sgml` described
   `positions=on` as enabling "index-only" phrase without ever saying the default
   costs SECONDS at scale.  Both now carry the measured table plus the
   double-quote syntax note (and the SGML was verified to actually render).
   **Considered and declined: a lazy phrase gate.**  Feasible without a format
   change (the block header carries `posbytelen`; `wand_load_block` simply does
   not copy the position bytes), but the profile bounds it: the adjacency test is
   only 4.3% of the query, `bm25_collect_matches` materializing all 361,465
   docids is 21.2%, and WAND ranking + the doclen path -- which both stay -- are
   37%.  Ceiling **~229 -> ~150 ms (~1.5x)**, which does not close the 5-10x gap
   to pg_search's 22.9 ms, in exchange for changing `WandCursor` on the hot path
   that already caused 1.5.5/1.5.6.  Revisit only if a field report shows ranked
   phrase latency mattering AFTER positions are enabled.

5. **`WITH (positions=off)` — heap-side only.**
   An option to omit token positions from the heap `ftsdoc` for phrase-free
   workloads: smaller heap column, faster build/insert/merge. It does **not**
   shrink the bm25 index (which stores no positions — see #4); the earlier
   "smaller index" framing was wrong. Phrase/NEAR require positions, so opt-in.

   **Interaction found while profiling phrase (2026-09-06) — read before
   implementing.** With index `positions=off` (the default), a phrase is answered
   by AND + a **heap recheck**, and that recheck (`fts_doc_matches` →
   `phrase_step`) derives adjacency from the heap `ftsdoc` positions.  Dropping
   heap positions therefore removes the only adjacency source for a
   default-built index.

   Note what `phrase_step()` does when a side lacks positions: it falls back to
   presence-only AND ("recall preserved, precision degraded", per its comment) —
   i.e. it would answer a phrase with a conjunction and report it as a phrase
   match.  **Verified 2026-09-06 that this is currently unreachable**, so it is
   not a live bug: the `ftsdoc` text-input parser *synthesizes* positions from
   token order when the literal supplies none (`'bravo alpha'::ftsdoc` →
   `'alpha':1@2 'bravo':1@1`), so `FTS_DOC_HAS_POS` holds for every parsed doc,
   and adjacency is enforced (reversed-order phrase → false, forward → true).
   `to_ftsdoc()` and the tsvector path both set the flag unconditionally too.

   So the constraint on this item is: a heap-side `positions=off` would be the
   **first** way to construct a positionless doc in practice, converting that
   dormant fallback into a live silent-wrong-answer path.  Implement it only with
   either (a) index `positions=on` required before heap positions may be dropped,
   or (b) a clear error for phrase/NEAR when neither side carries positions — and
   consider changing the `phrase_step` fallback to an error at the same time, so
   it cannot degrade silently if some future path does produce such a doc.

6. **COUNT / aggregation Custom Scan pushdown. [DONE]**
   Implemented in `pg_fts_customscan.c`: `_PG_init` installs
   `create_upper_paths_hook` (count) and `set_rel_pathlist_hook` (ranked), so a
   plain `count(*) WHERE col @@@ query` is planned as `Custom Scan (FtsCount)`
   with no explicit `fts_count()` call and no lossy bitmap heap recheck.  Verified
   again 2026-09-06 during phrase profiling: `EXPLAIN` on
   `count(*) ... WHERE d @@@ to_ftsquery(...)` shows `Custom Scan (FtsCount)`, and
   the measured cost is 2.20 ms for a 734,896-match term (a single plain term
   short-circuits to the dictionary df with no posting decode at all).  The cost
   model was repriced as the index-only visibility-map count it performs so the
   planner picks it at scale.  This item was simply never marked done.

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
   The batched tombstone filter (`sm_contains_many`) is integrated into the
   merge path.  The WAND ranked cursor now uses the forward-resume cursor
   (`sm_contains` with an `sm_cursor_t`) rather than the 8-way MRU cache
   (`sm_contains_cached`): the ranked scan visits docids in monotonically
   non-decreasing order against a read-only tombstone map, so a single-chunk
   resume cursor is O(postings + chunks), whereas the MRU cache degenerated to
   an O(chunks) head-walk per lookup once an ascending scan ran past its eight
   cached chunks -- a segment with millions of tombstones turned a common-term
   top-k into tens of seconds (fixed in 1.4.1, validated 24s -> 2.5ms at 2M
   docs / ~4M tombstones).  TODO: quantify the merge-path `sm_contains_many`
   gain on a delete/update-churn workload where it should help.

## Benchmark / competitive

10. **Multi-engine real-corpus comparison — done; iterate.**
    Latest: `bench/RESULTS_5WAY_159b_2026-09-06.md` (1.5.9, identical single
    column, 8-run medians).  pg_fts has the **smallest index in the field**
    (1421 MB vs 1887 pg_textsearch / 2734 pg_search / 2902 vchord) and the
    **fastest exact `count(*)`** (2.20 ms vs pg_search 13.63; the other two
    cannot do it).  Against the like-for-like comparator pg_textsearch it is
    faster on rare (5.85 vs 7.36 ms), slower on mid (10.69 vs 7.96), 2.7x slower
    on common k10, 1.4x faster on common k100.  **The open gap is common-term
    ranked top-k** (55.97 ms vs pg_search 2.12) and phrase (90.70 vs 22.86) --
    see item 4a below.
   A clean 3-way comparison (build time, index size, per-query latency across
   selectivity bands) vs VectorChord-bm25 and Timescale pg_textsearch on 2.19M
   Wikipedia articles is in `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md`. It shows
   pg_fts trailing on ranked latency and index size (the codec gap, #4) while
   leading on query-language breadth and index-native COUNT. The follow-up is
   the format-v3 codec work (#4), not more benchmarking.

11. **[DONE 2026-09-01] `fts_search` SRF under-fetch safety.**
    The top-k over-fetch is tight (`k*2`). This is safe for the ordering scan
    (which retries), but the `fts_search()` SRF did not retry — under a
    heavy-delete workload where more than half the top rows are invisible it
    could return fewer than `k`. FIXED: `bm25_topk_visible` grows `wantk` and
    re-generates when the visibility loop ends with `nvis < k` and more
    candidates existed (bounded growth cap), keeping the generation-guard retry
    inside each attempt.

## Correctness / robustness (lower urgency)

12b. **[DONE 2026-09-01] Reserved query keywords cannot be searched as literal words.**
    The query lexer recognized `and`/`or`/`not`/`near` as operators
    unconditionally, so a phrase `"the and clause"` or `NEAR(near y, 2)` errored.
    FIXED: keyword tokens now carry their folded text, and the phrase + NEAR
    operand-collection loops accept keyword kinds as literal terms (matching
    to_tsquery, which lexes them as lexemes).  Regression tests
    (`kw_phrase_*`/`kw_or_hit`/`kw_in_near_hit`, `simple` config so the words are
    not dropped as stopwords).  The ambiguous BARE top-level `and & x` case is
    deliberately left as-is (changing top-level keyword handling risks breaking
    real AND queries; low value since these are stopwords on NL corpora).

12. **[DONE 2026-09-01] Sparsemap error-path leaks.**
    `sm_create` maps (libc malloc, not palloc) in `bm25_bulkdelete` /
    `bm25_segment_docids` leaked on an `ereport` between create and `sm_free`.
    FIXED with PG_TRY/PG_FINALLY (volatile cleanup pointers, resynced before
    each throw because `sm_add_many_grow` reallocs `*map` even on partial
    grow-then-fail).  `bm25_read_blob` buffers are palloc'd (auto-freed), left
    alone.  Separately, a genuine sparsemap UPSTREAM bug (`__sm_insert_data`
    offset/length convention mismatch, a latent masked over-write) was found and
    reported to the sparsemap project.

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
