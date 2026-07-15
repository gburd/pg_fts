# fts_vacuum at multi-GB scale — EC2 finding (2026-07-15)

Instance: r7i.4xlarge, Fedora, PG17, `shared_buffers=32GB` (4M buffers),
123GB RAM, 300GB gp3 on /data. HEAD 2984590 (the two-phase VACATE->PACK
`fts_vacuum` fix). Terminated + fully cleaned up after the run.

## Workload
- 2.5M synthetic docs, mixed-Zipfian vocabulary, `to_ftsdoc(body)` fts index
  `WITH (positions=on)`. Built size ~4306 MB in ~4:02.
- Bloat: DELETE 750k, `fts_merge` (no-op), INSERT 200k + `fts_merge` (2:16,
  coalesced churn into the main segment, write-before-free roughly doubled the
  file), DELETE 66k. Result: **8007 MB for 1.884M live docs** — a genuine
  free<live bloat layout with ~4GB dead/free interleaved.

## Result: FAIL (operability). Not a correctness failure.
- `SELECT fts_vacuum('docs_bm25')` ran for **>3 hours** and did not complete.
- It did NOT respond to `pg_cancel_backend` or `pg_terminate_backend` within
  the observation window.
- gdb (3 stacks): the backend was pinned on-core (state=active, wait_event
  NULL) inside
  `bm25_truncate_free_tail -> RelationTruncate -> smgrtruncate2 ->
   DropRelationBuffers -> InvalidateBuffer` (pg_fts_am.c:2212).
- The sampler showed the file GREW 8007 -> 10283 MB during the vacate phase (as
  designed: extend-only vacate writes a fresh high copy before freeing the old),
  then wedged in the truncate.

## Correctness held (important)
- After forcing the box down, before that: index-scan count == seqscan ground
  truth for a real term (`zzrareterm`: idx 268 == seq 268) with
  `client_min_messages=warning` and NO warning on the query path. The index
  returns correct answers.
- The "truncated posting block ... REINDEX" WARNINGs in the vacuum log were the
  conservative decode-hardening path firing during the vacuum's full segment
  scan; they did not correspond to wrong query results. (Worth a follow-up to
  understand why the vacuum's scan trips the hardening path when the query path
  does not — possibly the extend-only rewrite's intermediate layout — but it is
  not a query-correctness bug.)

## DIAGNOSIS (2026-07-15, self-driven run, PG18, shared_buffers=16GB)
780 MB bloated index (99961 blocks, ~51% free -> ~380MB floor), 750k live docs.
Instrumented bm25_vacuum_compact with per-phase elog(LOG) timing. Result:

| phase | dt | nblocks after |
|-------|-----|---------------|
| pass 0 vacate | 17,653 ms | 149285 (grew ~1.5x, expected) |
| pass 0 pack   | 16,577 ms | 149285 |
| pass 0 truncate | 23,661 ms | 49325 (reclaimed to the floor!) |
| pass 1 vacate | 16,637 ms | 98649 (re-grew an ALREADY-COMPACT index) |
| pass 1 pack   | 16,461 ms | 98649 |
| pass 1 truncate | 81 ms | 49325 (converged -> stop) |
| **total** | **91,072 ms** | 49325 = 385 MB |

Final 385 MB (from 780), parity idx==seq (zzrareterm 300==300). CORRECT, but 91s
for a 780MB index. At ~8GB (10x) that is ~15min+, and the truncate sweep grows
with shared_buffers.

## Two cost drivers (both fixable, NEITHER needs surgical relocation)
1. **DOMINANT: a wasted extra full pass.** Pass 0 already reached the floor
   (49325 blocks) after its truncate. But the loop only stops when a pass makes
   NO progress -- so it runs pass 1, which VACATES the already-compact index
   (re-growing 49325->98649, +33s of vacate+pack) just to re-truncate back to
   49325 and discover it converged. That entire second pass
   (vacate+pack = ~33s here, ~5-6min at 8GB) is pure waste. FIX: detect
   convergence BEFORE rewriting -- if the free space BELOW the highest live
   block is already negligible (front-packed), the index is at the floor; skip
   the pass. This was the intent of the earlier "freebelow" check that a prior
   revision removed; reinstate it as a PRE-pass guard.
2. **The single necessary truncate is O(NBuffers).** pass-0 truncate = 23.7s at
   16GB shared_buffers (DropRelationBuffers scans all buffer headers in a
   non-interruptible critical section). Unavoidable for one truncate, but only
   paid ONCE if driver 1 is fixed (no wasted passes = no extra truncates). It
   is also why cancel didn't land in the 3h run -- the wedge was inside PG's
   truncate critical section.

## The fix (low-risk, no surgical relocation, no format change)
Add a pre-pass front-packed check: before each vacate/pack, scan the FSM for
free space below the highest live block; if it is <= a small threshold
(e.g. max(nblocks/50, 8)), the index is already front-packed -> break (only a
final tail-truncate needed, if any). This makes the common bloated case ONE
vacate+pack+truncate (pass 0) and an already-compact index a near-no-op
(no rewrite at all). Interruptibility outside the single truncate is already
covered by the 9 CHECK points. Validate locally via the flake vconv test, then
ONE final scale confirmation.

Refined after reading the code: the reviewer earlier proved the single-segment
case converges in ONE pass, so the 3h was ~one pass, i.e. ONE vacate + ONE
pack + ONE truncate -- not repeated passes. Two costs, both scale-only:
1. The two-phase VACATE->PACK rewrites the ENTIRE multi-GB segment TWICE per
   pass by construction: vacate = `bm25_compact_to_one(index, true)` reads all
   live pages and writes a fresh HIGH copy; pack = `bm25_compact_to_one(index,
   false)` reads it again and writes a LOW copy. That is >= 2x the segment size
   in reads AND writes (~16GB of I/O for an 8GB segment) plus full
   decode/re-encode CPU for every posting, twice. THIS is the hours-consumer.
2. `DropRelationBuffers` (inside `RelationTruncate`) is O(NBuffers): it scans
   all 4M buffer headers in a NON-interruptible critical section. One truncate
   is seconds at 4M buffers -- not the dominant cost here, but it IS why the
   final step could not be cancelled (gdb caught it mid-sweep). The 9
   CHECK_FOR_INTERRUPTS points cannot help inside PG's truncate critical
   section.

So option A (cap passes) will NOT help -- it is already ~1 pass. The fix must
cut the WRITE VOLUME: do not rewrite the whole segment twice.

## Options for the fix (measure before committing)
B (now primary). Surgical tail relocation: relocate only the live pages that
   sit ABOVE the eventual truncation point into existing low free holes, then a
   single truncate. Pages already low are never rewritten. Write volume ~ the
   dead-space size, not 2x the whole segment. More code (the relocation the
   prior two agents deferred), but it is the only option that removes the
   quadratic-feeling cost at scale.
C. If B is too invasive: at least collapse to a SINGLE full rewrite (low-bias)
   plus a one-time end truncate, accepting that on a free<live layout one
   rewrite may not fully pack (the very problem the vacate solved) -- so B is
   preferred.
Kill criterion for the fix: on this exact EC2 workload (2.5M docs, positions=on,
~8GB bloated, shared_buffers=32GB) `fts_vacuum` must complete in a bounded time
(target: minutes, not hours), be cancelable within seconds outside the single
truncate sweep, still shrink to near the floor, stay stable, never grow past
pre-call, and keep query parity. Do NOT ship 1.0.0 until this holds at scale.

## FIX VALIDATED at scale (2026-07-15, self-driven, PG18, shared_buffers=16GB)
Pre-pass guard (bm25_index_is_compacted): skip the vacate+pack when the index
is already front-packed AND single-segment; otherwise proceed (so multi-segment
indexes still coalesce). Same 780MB / 750k bloat as the diagnosis.

| metric | before fix | after fix |
|--------|-----------|-----------|
| first fts_vacuum | 91,072 ms (2 passes) | **36,820 ms (1 pass)** |
| reclaim | 780 -> 385 MB | 780 -> 385 MB (identical) |
| second fts_vacuum | full wasted pass | **3.157 ms (no-op)** |
| parity idx==seq | 300==300 | 300==300, common 153452==153452 |
| decode warnings | present | **0** |
| cancel mid-rewrite | (n/a) | **~1053 ms**, index stays valid |

- 2.5x faster first vacuum (wasted pass eliminated); repeat vacuum on a compact
  index is now ~3ms instead of a full 91s rewrite (matters for autovacuum).
- The one remaining non-interruptible step is the SINGLE DropRelationBuffers
  truncate sweep (inherent to PostgreSQL; O(NBuffers)); now paid once, not per
  wasted pass. Cancel during the rewrite phases lands in ~1s.
- No on-disk format change; version unbumped.

VERDICT: the multi-GB fts_vacuum operability blocker is resolved. The prior
>3h/non-cancelable behavior was the wasted-extra-pass compounding the O(NBuffers)
truncate; both are addressed.
