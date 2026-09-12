# pg_fts — roadmap (planned enhancements, not yet implemented)

Enhancements that are designed or prototyped but not yet shipped, tracked so
they are not rediscovered. Ordered roughly by value.

## Performance

P1. **`VACUUM` did not reclaim pg_fts bloat -- it GREW it. [PARTLY FIXED 2026-09-12 --
   ~6x better, requirement NOT yet met]** (`bench/P1_VACUUM_NO_RECLAIM_2026-09-11.md` for the defect,
   `bench/RESULTS_SELF_LIMITING_2026-09-12.md` for the fix)
   Before: three consecutive `VACUUM`s on an insert-heavy index went
   7,021 -> 7,734 -> 8,423 -> 9,111 MB, reclaiming nothing (+~690 MB/pass, unbounded).
   Root cause MEASURED, not inferred: the gate and predicate were both CORRECT
   (`nblocks=912246 freeblks=853384 (93.5%) gate_pass=1 is_compacted=0`), and the server
   log gave it -- **`ERROR: canceling autovacuum task`**. Cleanup holds the maintenance
   lock across flush -> merge -> compact, autovacuum yields to any conflicting lock
   request, and the merge had already written a fresh extend-only copy. **A cancelled
   pass was strictly worse than no pass** -- that is what made it unbounded.
   **Fix (two small edits):** (1) `bm25_merge_segments` truncates its own free tail
   before returning, establishing the invariant *a merge never leaves the index bigger
   than it found it*; (2) `bm25_vacuumcleanup` truncates UNCONDITIONALLY before the gated
   rewrite, so a later cancellation still leaves real progress. Online-safe under SUEL
   because scans use `bm25_scan_readbuf()` (out-of-range block = end-of-chain, added in
   1.5.7 for exactly this).
   **No new scheduling mechanism needed:** the insert path already calls
   `bm25_merge_segments` opportunistically under a conditional lock (`:5325`), so making
   that function self-truncating made *ingest itself* self-limiting.
   **Verified:** six rounds of 45k inserts, no `fts_vacuum`, no manual merge, plain
   `VACUUM` only -- settles ~1 GB, size grows SUBLINEARLY with data (+48% for +92% rows)
   instead of per pass, queries served throughout. Round 1 does not reclaim (no
   contiguous tail exists yet); round 2 absorbs it. Convergence takes at most two
   cleanup cycles, which autovacuum supplies continuously.
   **MY OWN TEST CAUGHT ME OVERCLAIMING.** I first read the six-round run as bounded and
   wrote it up that way. The regression test added to `t/010` disproved it: with **no rows
   added at all**, three VACUUMs still go 29 -> 41 -> 52 MB, ~11 MB per pass. So the
   six-round "+110 MB per round" was per-PASS growth that I partly attributed to data
   growth. Per-pass growth is 6x smaller, not gone.
   **Why it remains:** `bm25_vacuum_compact`'s vacate phase deliberately EXTENDS by the
   live size so freed pages form one contiguous region, then the pack phase moves data
   back down. An interrupted pass leaves that extension. Truncating the merge's own tail
   removed one growth source, not this one.
   **The change that would actually clear the requirement:** make the vacate phase reuse
   low free blocks instead of extending. The machinery already exists --
   `bm25_alloc_begin` hands out lowest-free-first, and `bm25_page_recyclable` already
   makes low reuse safe under SUEL -- so compaction would shrink monotonically and an
   interruption could never be a net cost. That is the next step, and it is the real fix.
   Docs (README, `doc/pg_fts.sgml`) now say a periodic `fts_vacuum` is still recommended,
   rather than the "no scheduling required" claim I briefly published.

P0. **VACUUM never completes on a delete-heavy index. [FIXED in 1.6.1, qualified at
   scale]** (`bench/P0_VACUUM_HANG_2026-09-10.md`,
   `bench/data_p0_2026-09-10/qualification.log`)
   `DELETE` 312k of 2.19M rows then `VACUUM`: the backend pinned a core and never
   returned -- 4h39m of CPU, 99.75% of samples in `__sm_get_chunk_offset`, reproduced
   twice. **Now 393 s and completes**, results identical to sequential-scan ground
   truth at every stage.
   **One mistake in TWO places, and fixing the first only exposed the second:**
   (1) `bm25_merge_segments_streaming` walks terms in sorted order so the docid
   sequence resets at every one of millions of term boundaries -- no sparsemap
   accelerator (MRU cache, resume cursor, or batched `sm_contains_many`) survives
   that, each paying `O(chunks)` per term. Fixed by decoding the read-only tombstone
   map ONCE per source into a dense bitmap and testing in O(1).
   (2) `bm25_bulkdelete` declared its `sm_cursor_t` INSIDE an ascending walk, so it
   reset every iteration. Fixed by hoisting it.
   Same class as the ranked-scan pathology fixed in 1.4.1 (24 s -> 2.5 ms); these two
   paths never got the equivalent fix.
   **Testing lesson recorded:** the full local gate passes on the unfixed code AND on
   two wrong fixes. `gdb` on the live backend, not `perf` callchains, is what isolated
   it. This is exactly what item 9's never-completed delete-heavy measurement would
   have caught.

C1. **Concurrent throughput. [DONE 2026-09-11 -- cross-engine, all four]**
   (`bench/RESULTS_C1X_CROSSENGINE_2026-09-11.md`, data in `bench/data_c1x_2026-09-11/`)
   Like-for-like: one documented query form per engine, same shape, same instance type
   (r6id.4xlarge, 16 vCPU / 8 physical cores), pgbench 1/8/16/32 clients, 30 s per cell.
   **No engine collapses.** All four rise steeply to 8 clients then plateau -- the host
   is CPU-subscribed at 8 backends + 8 pgbench threads, so the ceiling is the box, not
   the engines. Applies equally to all four, so the comparison stands.
   **pg_fts has the BEST scaling factor and the WORST absolute ranked throughput.**
   10.7x rare / 10.0x common (highest of the four; latency flat 9.9 -> 10.0 ms from 1 to
   8 clients while tps rises 8x) but from the lowest base: at 32 clients 1,076 tps rare
   vs pg_textsearch 8,349, and 208 tps common vs pg_search 4,298.
   **The common-term gap is WORSE under load: 20.7x, against 17x single-client.** Good
   scaling does not rescue a slow per-query cost, it multiplies it -- so this strengthens
   4a rather than deferring it.
   **`count(*)` is ours by a wide margin, now shown under load:** 2,923 tps / 10.9 ms at
   32 clients vs pg_search 513 tps / 62.3 ms (5.7x); pg_textsearch and vchord cannot do
   it at all.
   **CORRECTION I published and this run overturned:** I claimed vchord *collapses* under
   concurrency. It does not -- it peaks at 8 clients and declines only 4.7% (rare) /
   7.2% (common) by 32. Settled by a peak sweep (c=2/4/12/24/48 ->
   823/1,107/1,289/1,237/1,230 tps, flat top) plus mpstat (49.7% CPU at c=8 on 8
   physical cores, 99.8% at c=32). Its low 1->32 factor (2.0-2.4x) is because one client
   already consumes a full core, not degradation.
   Rig defects found and fixed: `git archive` excludes `bench/` (`.gitattributes`
   export-ignore) so the harness must be copied directly -- cost one wasted run; and
   `grep -q "shared_preload_libraries"` matched the COMMENTED default line, silently
   skipping pg_search's preload and producing all zeros. `underload.sh` now ABANDONS a
   band that yields no tps rather than recording 0, which would read as a result.

C2. **Ingest / update throughput. [pg_fts MEASURED 2026-09-11; cross-engine open]**
   (`bench/RESULTS_C2_INGEST_2026-09-11.md`, data in `bench/data_c2_2026-09-11/`)
   Ingesting 200k rows into a settled 1M-doc index, `autovacuum=off`:
   **ingest decays 41%** (371 -> 217 rows/s) and **ranked latency grows 16%**
   (7.6 -> 8.8 ms) then PLATEAUS from batch 5; `fts_merge` restores latency to 7.8 ms
   (pristine was 7.6), so the degradation is pending-list occupancy, not permanent.
   The bounded plateau is the reassuring half; the steady ingest decay is the real cost.
   Maintenance: `fts_merge` 292.6 s to absorb 200k rows; `DELETE` 300k + `VACUUM` 242 s
   (independent confirmation the 1.6.1 P0 fix holds at a second scale/corpus).
   **ACTIONABLE FINDING, corrected same day -- the transient is INSERTs, NOT the merge.**
   Reproduced at two scales: the file reaches 7,716 MB (250k+50k) and 32,378 MB
   (1M+200k) **before any merge runs**; `fts_merge` then adds only ~7%. Cause:
   `bm25_insert` stores a pending doc VERBATIM and one that does not fit a page becomes
   its own ONE-DOCUMENT SEGMENT (`pg_fts_am.c:5347-5352`). On this corpus the average
   ftsdoc is 8,861 B against an 8,192 B page and **32.7% of docs exceed it**, which also
   explains nsegments 1->8 during ingest. Verbatim storage explains only ~1.8 of 30.8 GB;
   the one-doc-segment path is the other ~19x.
   **Corpus-dependent, not general** -- it scales with the fraction of docs larger than a
   page. README + `doc/pg_fts.sgml` now say so; my first version attributed it to merge
   and stated a bare 49x, which would have sent operators to instrument the wrong
   operation. I had flagged it as needing a second scale and published it anyway.
   **Two harness defects caught because the first run was physically impossible**
   (6.5M rows/s): `psql -v` does not expand a bare `:var` inside `-c`, so every INSERT
   was invalid and inserted nothing -- now asserted by a per-batch row-count check that
   aborts; and wrapping `psql` in `/usr/bin/time` folded ~10 ms of startup into each
   sample, producing a flat fake "10.0 ms" -- now measured server-side via `\timing`.
   **Still open:** cross-engine comparison (the rivals' ingest paths differ
   fundamentally, so it needs per-engine forms chosen as carefully as C1's), a longer run
   to find where ingest decay levels off, and reproducing the 49x transient at a second
   scale before stating it as a general rule.

C3. **Ranking quality (NDCG / recall) vs rivals. [NEW -- never compared]**
   `bench/ndcg.py` and `NOTE_RANKED_RECALL.md` validate OUR exactness (top-k parity
   against an exact `fts_bm25` sort, gated per release) but no relevance comparison
   against pg_search / vchord / pg_textsearch was ever run.  This matters more than
   usual because **pg_search does not stem** -- 495,580 hits for `year` where the
   correct English answer is 734,896 -- so latency alone is partly
   apples-to-oranges and quality is what would quantify it.

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

1. **Verify parallel merge at scale. [MEASURED 2026-09-08 -- it is SLOWER; do not
   enable]** (`bench/RESULTS_PARALLEL_MERGE_2026-09-08.md`)
   This item asked only for the speedup number, since parallel merge
   (`bm25_merge_all_parallel`) was already implemented and verified correct.
   Measured at 2.19M docs on an 8-segment 7,185 MB index: **serial 230.6 s vs
   parallel 333.5 s = 1.45x SLOWER**, and the parallel path emits a **19% LARGER**
   index (10,229 MB vs 8,606 MB). W=1 costs the same as W=3, so it is a fixed
   penalty for taking the path, not a scaling curve.
   Correctness is fine -- all 7 runs converged nsegments 8 -> 1 with identical
   match counts (year 734,896 / slovakia 10,875 / hungary 24,097).
   **Trap found:** at `max_parallel_maintenance_workers = 8` the workers register,
   start, and exit with code 0 within ~2 ms, so the merge silently runs SERIAL
   (confirmed with postmaster DEBUG1). Those runs looked fast because they *were*
   the serial path. Genuine parallel runs are the W=1 and W=3 ones.
   Likely cause of both effects (unverified): per-worker output streams pack pages
   independently, so the 19% growth is write amplification that also explains the
   slowdown -- a merge is sequential-I/O bound, not CPU bound.
   **Action: leave disabled and document that raising `mpmw` makes merges slower**
   (the opposite of operator intuition). Then either fix the fragmentation or
   consider removing the path, which carries real concurrency risk in a line that
   has already shipped three concurrency-fix releases for a measured negative.

2. **Level-2 recursive parallel merge (W → W/2 → … → 1). [BLOCKED by item 1's
   measurement -- do not start]**
   The idea: the current parallel merge does one parallel pass into
   (workers+1) segments then a serial final combine, so recursing would remove
   that O(index) single-threaded tail.
   **This is now moot until item 1 is fixed.** Measured 2026-09-08: taking the
   parallel path AT ALL is 1.45x slower than serial (333.5 s vs 230.6 s) and emits
   a 19% larger index, and W=1 costs the same as W=3 -- so the penalty is not in
   the serial tail this item targets, it is in going parallel in the first place.
   Parallelizing more of a path that loses to serial makes it worse.
   Prerequisite: understand and fix the per-worker output fragmentation (the 19%
   growth) so that parallel merge beats serial on a single pass. Only then does
   recursion have anything to add.

3. **Parallel build: fewer, larger per-worker segments. [CLOSED as scoped
   2026-09-09 -- premise is false]** (`bench/RESULTS_GATING_2026-09-09.md`)
   The premise was "a parallel build leaves many segments needing a merge".
   Measured across `maintenance_work_mem` x workers at 2.19M docs: **at
   `maintenance_work_mem >= 1GB` the build already leaves `nsegments = 1` and the
   follow-on merge is a 0.0 s no-op.** There is nothing to fix at realistic
   settings; the item was scoped against 64MB-era behaviour. At the 64MB default
   the same build leaves 8 segments plus a 216 s merge and lands twice as large
   (8,613 vs 4,605 MB) -- so the remedy is **raise `maintenance_work_mem`**, which
   is documentation (now in README + `doc/pg_fts.sgml`), not code.

3a. **Per-worker output fragmentation. [CLOSED 2026-09-09 -- hypothesis disproven,
   claim withdrawn]** (`bench/DIAG_WORKER_FRAGMENTATION.md`,
   `bench/REVIEW_WORKER_FRAGMENTATION.md`, `bench/BENCHMARK_SUMMARY.md`)
   I opened this on a measured "parallel build is ~17% larger" delta. **That delta
   was measured before `fts_vacuum` and does not survive it.** Re-measured in an
   isolated database at `maintenance_work_mem=1GB`: serial 4,605 MB pre-vacuum ->
   **1,420 MB** post; 4 workers 5,365 MB pre-vacuum -> **1,420 MB** post. Identical
   to the megabyte, identical match counts, both `nsegments=1`. A parallel build is
   faster (464 s vs 523 s) and leaves more *reclaimable residue*, not a bigger
   index. **The claim is withdrawn from README, CAPABILITIES, the SGML reference
   and the benchmark summary.**
   The "per-worker partial pages" hypothesis is disproven twice over: empirically
   (live pages measure **98.8% full**, 173,521 of 173,529 above 90%) and
   arithmetically (a segment writes at most ~4 chain-tail partial pages because
   writers advance only when the next item does not fit and all terms share ONE
   posting chain, bounding total slack at ~4 MB against deltas of 781-1,623 MB).
   The residue is a **deliberate safety property**: merge output is allocated
   extend-only (`pg_fts_am.c:4665-4672`) so a committed merge's freed inputs cannot
   be recycled as the next merge's output while in-flight read chains still point
   through them -- the comment says the alternative is "a wrong read or a SIGBUS".
   `bm25_truncate_free_tail` reclaims only a contiguous tail (`:4446-4449`), so
   buried freed pages wait for compaction. Nothing to fix; documented instead.

3b. **`bm25_merge_all` runs the parallel pass AND THEN the serial collapse.
   [PREMISE NARROWED 2026-09-11 -- likely not worth doing]**
   Still true as code: `pg_fts_am.c:4191` calls `bm25_merge_all_parallel()` and on
   success falls THROUGH to the serial collapse loop with no early return, so a parallel
   `fts_merge` does the parallel pass plus the full serial collapse.
   **But the cost model I attached to it is wrong.** I had generalised from production
   logs (`merging 8 of 128` -> `8 of 121` -> ...) to "a merge does
   O(nsegments/FANOUT) extend-only passes". Measured directly at two scales
   (`bench/RESULTS_C2_INGEST_2026-09-11.md`): **passes=2**, each logging
   `merging 1 of 1 segments`. The ~18-pass reading applied to one specific state -- a
   128-segment index left by a parallel build -- not to merges in general.
   So the remaining value is only "stop doing the work twice on an index that actually
   has many segments", which by definition means a parallel build, which is itself
   documented as a size regression not to use. **Recommend closing unless a field report
   shows a many-segment index being merged in production.** If picked up, first measure
   `nsegments` immediately after `bm25_merge_all_parallel` returns -- that is the number
   the whole premise rests on and it has never been captured.

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


   **RE-PROFILED on the shipped build 2026-09-09** (`bench/RESULTS_GATING_2026-09-09.md`):
   doclen is the dominant cost in every band, and far more so than I had recorded --
   rare 68.9%, mid 71.6%, common 45.2%, versus `topk_candidates_range` at 6.8% /
   6.0% / 37.2%. So the target is `bm25_doclen_cursor_load_page`, not the WAND
   driver.
   That also **re-sizes the sidecar format change upward**: 1.5.10's CHANGELOG
   called a mid-block start "worth at most ~2x of a portion of the query", reasoning
   from the common profile where `load_page` is 28.3%. On rare/mid it is ~65%, so
   halving the gap-decode prefix is worth roughly **1.5x on the two bands the field
   actually queries** (rare 5.89 -> 3.99 ms, mid 10.64 -> 7.14 ms). Still a format
   change requiring dual-read + an upgrade path + a MINOR release under our
   format-preservation rule -- but it is now the best-sized remaining performance
   item and should be judged on that basis rather than dismissed.

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

5. **`WITH (positions=off)` — heap-side only. [NO-GO as scoped, 2026-09-08]**
   Analysed in `bench/PLAN_HEAP_POSITIONS_OFF.md`. The idea: omit token positions
   from the heap `ftsdoc` for phrase-free workloads (smaller heap column, faster
   build/insert/merge). It does NOT shrink the bm25 index, which stores no
   positions by default; the old "smaller index" framing was wrong.

   **Rejected on measured size vs. measured risk.** The saving is exactly
   `4 x doclen` bytes -- about **16%** of a short doc's `ftsdoc` and 30-41% on a
   2000-token one -- and because `ftsdoc` is `STORAGE = extended`, the on-disk
   delta is the *compressed* one, smaller still. Meanwhile the corpus that would
   benefit most (long documents) is precisely the one our own measurements show
   pays **36x** for losing positional phrase (see 4b). Bad trade.

   It also cannot be expressed cleanly: the heap value is produced by a function
   call (`to_ftsdoc(...)`), not index DDL, so a `WITH (...)` reloption cannot
   control it.

   And the safety argument that motivated a guard here is now moot in the right
   way: the silent phrase-degradation bug it would have amplified **has been
   fixed** (an unverifiable phrase returns false, matching PostgreSQL's
   documented `OP_PHRASE` behaviour; see commit "fix: an unverifiable phrase must
   be FALSE"). Note the guard idea "require index `positions=on`" was itself
   unworkable -- `fts_doc_matches` is reachable by seq scan with no index at all.

   Revisit only if a field report shows heap `ftsdoc` size actually dominating a
   phrase-free workload, and then as an explicit function variant rather than a
   reloption.

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

7. **Parallel scan (`amcanparallel`). [ALREADY BUILT AND REVERTED -- NOT OPEN]**
   **This item was stale and I left it looking open for months.** A complete
   parallel ranked CustomScan was implemented, verified byte-exact, measured, and
   deliberately reverted -- see `bench/NOTE_PARALLEL_RANKED.md`, whose first line
   is "built, measured, reverted". Two reasons, both still valid:
   (a) an Amdahl ceiling around 30% of the query, and (b) parallel workers refused
   to launch from inside `ExecCustomScan` on EC2 (0 workers, silent serial
   fallback). The docid-range plumbing was deliberately KEPT and is still in the
   tree (`pg_fts_am_scan.c:3851`, `:2759-2761`, `:2932-2933`, `:3000-3001`) as a
   foundation if a future design beats that ceiling.

   Re-analysed 2026-09-08 against the post-1.5.10 numbers
   (`bench/PLAN_PARALLEL_SCAN.md`): still a **NO-GO as a latency fix**. Amdahl at
   p=0.88 gives W=2 -> 20.3 ms, W=4 -> 12.3, W=8 -> 8.3 (realistically ~11.8),
   against pg_search's **2.12 ms** -- it closes at most ~4.4x of a ~17x gap while
   burning 8 CPUs, and the shipped default `max_parallel_workers_per_gather = 2`
   would give real users ~20 ms.
   Additional blockers that analysis surfaced: `nsegments=1` is *enforced* by
   insert-time tiered merge (`pg_fts_am.c:5234`) and autovacuum compaction
   (`:5965`), so per-segment parallelism divides by one on every healthy index;
   intra-segment docid ranges need O(W^2/2) header walks because posting chains
   are singly-linked with gap-encoded docids; the 1.5.7 generation guard becomes W
   independent guards whose failure mode is an intermittently-truncated top-k that
   `parity_check.sh` would NOT catch; and no core AM combines `amcanorderbyop`
   with `amcanparallel`, so we would be first with no reference implementation.
   (Exactness itself is sound: `idf` is summed globally before partitioning
   (`:3999-4003`), so a worker's local threshold is always <= the global one and
   it under-prunes rather than losing results.)

   **Caveat on my own numbers -- now RESOLVED (2026-09-09).** The "39% candidates /
   43% doclen" split I had been quoting was never captured from a real run. A fresh
   `perf` on the shipped build (`bench/RESULTS_GATING_2026-09-09.md`) gives, for
   common `year`: candidates 37.2%, doclen 45.2% (`load_page` 28.3% + `lookup`
   16.9%), `wand_load_block` 6.4%. So doclen is the LARGER half, not candidates.
   The NO-GO above is unaffected (the ceilings differ by <1 ms between splits), but
   the target for further work is `bm25_doclen_cursor_load_page`, and rare/mid are
   far more doclen-dominated still (68.9% and 71.6%).

8. **Storage AIO / `read_stream` prefetch for the cold merge full-scan.**
   The build heap scan already gets core `read_stream` prefetch for free. The
   remaining candidate is the cold merge full-scan of posting pages, *if*
   `BM25SegMeta` recorded a contiguous posting block range so a `blk++`
   read_stream callback could prefetch. Low priority — pointer chains and WAND
   block-skipping defeat prefetch elsewhere. Deferred until a cold-merge I/O
   bottleneck is measured.

## Sparsemap (vendored)

9. **Exercise batch/cached sparsemap APIs under a delete-heavy workload.
   [MOSTLY ANSWERED 2026-09-10 -- it found a P0]**
   The delete-heavy measurement this item asked for was finally run and it found the
   VACUUM hang above (see P0). That is the answer to "what does the merge path do
   under delete pressure": it did not terminate. Both offending probe patterns are
   fixed and qualified. What remains genuinely open is only the narrow original
   question of whether batched `sm_contains_many` beats the alternatives in the merge
   path -- moot for now, since the merge path no longer probes the sparsemap per
   posting at all (it uses a dense bitmap).
   Prior partial result retained below.
   [PARTIAL 2026-09-08]** (`bench/RESULTS_SPARSEMAP_2026-09-08.md`)
   The ranked-scan half was already settled and shipped: the 8-way MRU cache
   (`sm_contains_cached`) degenerated to an O(chunks) head-walk once an ascending
   scan ran past its eight cached chunks, so a segment with millions of tombstones
   turned a common-term top-k into tens of seconds; the forward-resume cursor
   (`sm_contains` + `sm_cursor_t`) fixed it (24 s -> 2.5 ms at 2M docs / ~4M
   tombstones, shipped in 1.4.1). Only the MERGE path's `sm_contains_many` was
   open.
   Measured at ZERO tombstone density with three separately compiled arms
   (stock / batched / cursor, each md5-verified at load): merge 231.6 / 233.7 /
   233.2 s and a **byte-identical** output index. Spread 0.9% -- so the batched
   filter is **not a regression**, which is all a zero-density run can show.
   **The delete-heavy measurement did NOT succeed and the TODO stands.** Three rig
   defects, documented in the note: the `PGFTS_BENCH_NO_CLEANUP_MERGE=1` control
   the rig relies on **does not exist in our source** (a no-op, so timed merges may
   have been racing autovacuum compaction); every delete-heavy cycle recorded
   `tombstones_in_index=0`; and the rig double-launches each cycle so the two
   copies stop each other's cluster. A redo needs a real suppression mechanism, a
   verified non-zero tombstone count before the timed merge, one cycle per
   invocation, and unbuffered output -- build it fresh rather than repairing that
   rig.

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
