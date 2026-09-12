# Self-limiting index maintenance: no scheduled `fts_vacuum` required (2026-09-12)

**Requirement:** pg_fts indexes must be incrementally vacuum-able while remaining
online and in use, must make progress, and must not require the operator to schedule
or manage vacuum, nor accept downtime.

**Status: substantially improved, requirement NOT fully met.** Per-pass growth is cut
**~6x** (690 MB → ~110 MB per pass at 200k docs) and the index is now dramatically better
behaved under continuous ingest — but it still grows by a bounded amount **per vacuum
pass**, so the "must make progress and never require scheduling" bar is not yet cleared.
See "The overclaim my own test caught" below; I initially read this run as a clean pass
and it is not.

## The defect this replaces

From `bench/P1_VACUUM_NO_RECLAIM_2026-09-11.md`: three consecutive `VACUUM`s on an
insert-heavy index went **7,021 → 7,734 → 8,423 → 9,111 MB**, reclaiming nothing —
~690 MB added per pass, indefinitely. Cause: cleanup holds the maintenance lock across
flush → merge → compact; autovacuum yields to any conflicting lock request
(`canceling autovacuum task`); the merge had already written a fresh extend-only copy,
so a cancelled pass left the index strictly **larger** than it found it.

The property that made this unbounded was not the missed compaction — it was that a
cancelled pass was *worse than no pass*.

## The change

Two edits, both small, and the first is the one that matters:

1. **`bm25_merge_segments` truncates its own free tail before returning**
   (`pg_fts_am.c`, end of the tiered-merge loop). The merge still allocates
   extend-only — that is a correctness requirement, since reusing a just-freed page
   while an in-flight read still threads through it risks a wrong read or SIGBUS — but it
   now gives back the contiguous tail it created. This establishes the invariant that
   fixes the class of bug: **a merge never leaves the index bigger than it found it.**
   O(free tail), no data rewrite, no extra lock (the caller already holds the
   maintenance lock).

2. **`bm25_vacuumcleanup` truncates unconditionally, before the gated rewrite.** Tail
   truncation cannot be wasted work, so it no longer sits behind the ≥25%-free gate; and
   doing it *first* means that if the vacate+pack is then cancelled, the pass has still
   made real progress rather than none.

**Why this is online-safe under `ShareUpdateExclusiveLock`:** scans read through
`bm25_scan_readbuf()`, which treats an out-of-range block as end-of-chain — added in
1.5.7 for exactly this reason. Truncation therefore cannot break a concurrent reader,
and no stronger lock is needed.

**Why no new scheduling is needed:** the insert path already calls
`bm25_merge_segments` opportunistically under a *conditional* maintenance lock
(`pg_fts_am.c:5325`), skipping if another writer holds it. Since that function now
truncates its own tail, **ingest itself became self-limiting** — the mechanism runs on
the write path, not on a timer.

## Verification at scale

200,000-document base, settled to 228 MB. Then **six rounds of 45,000 inserts with no
`fts_vacuum` and no manual merge — only plain `VACUUM`**, `autovacuum=on`:

| round | after insert | after plain `VACUUM` | segments | query | rows |
|---|---|---|---|---|---|
| 1 | 6,854 MB | 7,416 MB | 1 | ok | 245,000 |
| 2 | 14,114 | **939** | 1 | ok | 290,000 |
| 3 | 7,672 | **1,058** | 1 | ok | 335,000 |
| 4 | 7,830 | **1,168** | 1 | ok | 380,000 |
| 5 | 7,978 | **1,278** | 1 | ok | 425,000 |
| 6 | 8,120 | **1,394** | 1 | ok | 470,000 |
| *explicit `fts_vacuum`* | — | **456** | 1 | — | 470,000 |

- **Bounded, not growing.** Steady state is ~1 GB against the previous unbounded climb.
- **Tracks data, not passes.** Rows grew **+92%** (245k → 470k) while post-vacuum size
  grew **+48%** (939 → 1,394 MB) — sublinear, so garbage is not accumulating across
  cycles.
- **Online throughout.** The ranked query returned its 10 rows in every round, during
  continuous ingest and vacuuming.

### Round 1 is a real transient, and here is why

Round 1 did not reclaim (6,854 → 7,416 MB). That is expected and it self-corrects:
tail truncation only reclaims a **contiguous** tail, and after the first merge the
output sits at the top with freed pages *below* it — no tail exists. The ≥25%-free gate
then fires on the following pass and the vacate+pack relocates live data downward, which
is exactly what round 2 shows (14,114 → 939 MB, absorbing round 1's leftover).

So **convergence takes at most two cleanup cycles**, and autovacuum supplies those
continuously. The operator schedules nothing. What an operator *may* still see is one
cycle's worth of transient growth after a large ingest burst.

## What `fts_vacuum` is still for

It reaches a tighter floor (456 MB vs ~1,394 MB steady state, 3.1×) because it always
performs the full vacate+pack rather than waiting for the gate. It remains the right tool
for a one-off reclaim after a bulk load or a mass delete. It is no longer required to
keep an index from growing without bound, which is the part that was previously a
scheduling burden.

## The overclaim my own test caught

I first read the six-round table as "bounded, tracks data not passes" and wrote that up.
The regression test I then added to `t/010_vacuum_delete_heavy.pl` disproved it within
minutes: with **no rows added at all**, three consecutive `VACUUM`s still went
**29 → 41 → 52 MB** — about **11 MB per pass**.

That reframes the six-round result. Post-vacuum size went 939 → 1,058 → 1,168 → 1,278 →
1,394 MB, i.e. **+110 MB per round** — and each round also added 45k rows, so I attributed
to the fix what was partly just data growth. Growth is still **per-pass**, not per-row;
it is simply 6× smaller than before.

**Why it remains:** `bm25_vacuum_compact`'s vacate phase deliberately *extends* the file
by the live size so the freed pages form one contiguous low region, and the pack phase
then relocates data back down. Any pass that does not complete both phases — the
cancellation this whole item is about — leaves that extension behind. Truncating the
merge's own tail removed one source of growth; it did not remove this one.

**What is genuinely fixed:** the unbounded ~690 MB/pass runaway, and the invariant that a
*merge* never leaves the index larger than it found it. **What is not:** compaction is
still grow-then-shrink, so an interrupted compaction still costs space.

**Next step, concretely:** make the vacate phase reuse low free blocks instead of
extending (the allocator already supports lowest-free-first via `bm25_alloc_begin`, and
`bm25_page_recyclable` already makes low reuse safe under `ShareUpdateExclusiveLock`), so
compaction shrinks monotonically and an interruption is never a net cost. That is the
change that would actually clear the requirement.

## Honest limits

- **Steady state is ~3× the achievable floor.** Bounded and predictable, but not
  minimal. Closing that gap means either lowering the 25% gate (which costs a full
  rewrite more often — the gate exists because an unconditional vacate+pack streams the
  whole index through the buffer pool twice) or making the rewrite incremental enough to
  run every cycle cheaply. Not attempted here.
- **Only sustained-ingest is verified by this run.** The delete-heavy path is covered
  separately by the 1.6.1 P0 fix and `t/010`, but the *combination* of continuous inserts
  and continuous deletes over many cycles is not yet measured.
- The one-document-segment amplification for large documents
  (`bench/RESULTS_C2_INGEST_2026-09-11.md`) is unchanged — it drives how large the
  per-round transient is, and is a separate item.

## Data

`bench/data_selfvac_2026-09-12/self_limiting.log`.


---

# Attempt 2: low-block reuse ("pack-first") — landed, residual growth NOT eliminated

Implemented the change identified above as the real fix: before the grow-then-shrink
vacate+pack, `bm25_vacuum_compact` now tries a **single low-first pack** —
`bm25_compact_to_one(index, false)` followed by a tail truncate — and only falls back to
vacate+pack if that made no progress.

Rationale unchanged and still sound: `bm25_alloc_begin` already hands out
lowest-free-first and falls back to extending only when it runs out, and
`bm25_page_recyclable` already makes low reuse safe under `ShareUpdateExclusiveLock`
with concurrent scans (phase 2 has always relied on both). When the file already holds
enough low free space — the bloated case we are called for — this reaches the same end
state while the file only ever shrinks, so an interruption is never a net cost. The
`for (pass < BM25_VACUUM_MAX_PASSES)` counter bounds the added `continue`.

**It did not close the gap.** With the change in, `t/010` still records
**35 → 52 → 69 MB** across three forced `VACUUM (INDEX_CLEANUP on)` passes with **no rows
added** — about 17 MB per pass.

## What I could not determine, stated plainly

I instrumented `bm25_vacuumcleanup` (gate inputs, truncate before/after) and the merge's
new tail-truncate with `elog(LOG, ...)`, forced `INDEX_CLEANUP on` so cleanup could not be
skipped, and **got no log output at all** while the growth still reproduced. So the writer
responsible for the residual ~17 MB/pass is on a path I have not identified. The leading
untested candidate is the **insert-time opportunistic merge** (`pg_fts_am.c:5325`, which
calls `bm25_merge_segments` under a conditional lock) rather than anything in the vacuum
path — which would mean the growth is attributable to ingest, not to vacuuming, and my
entire investigation was aimed at the wrong function.

I also burned significant effort on harness plumbing (nix caching the extension against
committed source; a local direct-build script failing silently under `set -e`) without
getting the diagnostic out. Recording that rather than presenting a tidy conclusion.

## Net state after both attempts

| | per-pass growth |
|---|---|
| before any fix | ~690 MB (unbounded accumulation) |
| after merge-truncates-own-tail | ~110 MB at 200k docs |
| after pack-first | unchanged at this scale (~17 MB on the small `t/010` index) |

**Kept:** both changes. The merge-tail truncate is a clear improvement with a measured
6× effect, and pack-first is strictly better-shaped (monotonic when it applies, falls back
safely when it does not) even though it did not move this particular number.

**Requirement status: still NOT met.** Growth per cleanup pass is bounded and far smaller,
but non-zero, so a periodic `fts_vacuum` remains the reliable way to hold an index at its
floor — as the docs now say.

**Next step, and it is a measurement not a code change:** identify the writer. Add a
counter or `elog` on the *insert* path's merge call and on `bm25_compact_to_one`, and
confirm which one extends the relation during a no-rows-added cleanup. Doing that first
avoids a third fix aimed at the wrong function.


---

# Attempt 3: the mechanism, finally measured — and why one-call reclaim cannot work

The previous two attempts failed for the same reason, which I could not see until the
instrumentation actually reached me. Recording it so a fourth attempt starts from the
real constraint.

## The plumbing error that hid it for two rounds

`elog(LOG, ...)` from the extension goes to the **TAP node's own server log**, not to the
nix build output. I had been grepping the build log and seeing nothing, and twice
concluded "the instrumentation never ran / the code is not reached". It was running the
whole time. Reading `$node->logfile` from inside the test surfaced it immediately.

## What the instrumentation showed

Per-cleanup, on an index with no rows added:

```
mergetail: 2366->2366 (+0)      <- and 4553->4553, 6740->6740 ...
```

The merge's tail truncate reclaims **+0 every single time**, while block count climbs
**2,366 → 4,553 → 6,740** (+2,187 blocks ≈ 17 MB per pass — exactly the observed growth).

**Why +0 is structural, not a bug:** the merge loop allocates extend-only, so its output
*is* the highest data in the file. `bm25_truncate_free_tail` needs the LAST block free, and
it never is. **My first fix (merge truncates its own tail) could not work on this path by
construction** — the `+0` is the proof.

## Then instrumenting the reclaim itself

Replacing that truncate with a low-first repack gave the decisive numbers:

```
mergereclaim: 2462 -pack-> 4660 -trunc-> 4660 (net +2198)   <- pack DID work, so it EXTENDED
mergereclaim: 1896 -pack-> 1896 -trunc->  615 (net -1281)   <- pack was a NO-OP, truncate won
mergereclaim: 4135 -pack-> 4135 -trunc->  730 (net -3405)   <- same
mergereclaim:  730 -pack-> 1459 -trunc-> 1459 (net  +729)   <- worked, extended again
```

**`bm25_compact_to_one` is write-before-free** — it writes the relocated segment before
freeing the old pages, which is exactly what makes a crash mid-compaction safe. So *any
call that does real work extends the file*, and only a call that is already a no-op leaves
a tail for the truncate to remove.

**Therefore reclaim inherently needs two distinct passes**: one to relocate the data, and a
later one whose pack is a no-op so the truncate can drop the freed tail. That is precisely
what the pre-existing vacate+pack+truncate **loop** does, and why it is a loop.

**Both of my earlier attempts tried to reclaim within a single call.** Neither could have
worked. I then tried an explicit two-round version inside the merge, and it was *worse*
(39 → 68 → 96 MB) — the second round extends again rather than settling, so two rounds is
not the right shape either.

## State reverted to the last verified-good build

`pg_fts_am.c` is back to the committed state: merge-truncates-own-tail plus pack-first,
both retained, full gate green, `t/010` at its honest bounded assertion (35 → 52 → 69 MB).
No unproven change is in the tree.

## What a fourth attempt must respect

1. **Write-before-free is non-negotiable** — it is the crash-safety property. Any design
   that reclaims in one call is wrong.
2. **Extend-only inside the merge loop is non-negotiable** — merge N+1 must not recycle
   pages merge N is still reading, and `bm25_page_recyclable`'s XID gate does not help
   because it is the same transaction.
3. So the reclaim must be a **separate later pass**, which is what
   `bm25_vacuum_compact`'s loop already is. The real question is therefore **not** "how do
   I make the merge reclaim" but **"why does that loop's gate not fire, or not converge,
   in this scenario"** — and note the earlier P1 instrumentation showed the gate *passing*
   with `is_compacted=0`, so it does run. The unexplained part is why its loop does not
   converge downward here.
4. Measure `bm25_vacuum_compact`'s per-pass block counts (it has `prevblocks` already) via
   the node log, using the `$node->logfile` route above rather than the build log.

**Requirement status unchanged: not met.** Docs continue to recommend a periodic
`fts_vacuum`. Three attempts, one real mechanism established, no regression shipped.


---

# Attempt 4: the writer is NOT in the vacuum path (2026-09-12)

Applied the constraint from attempt 3 and instrumented `bm25_vacuum_compact`'s loop via
the node log. That produced the answer, and it invalidates the target of all three
previous attempts.

## What the loop was doing

```
top0: nblocks=1910 is_compacted=0   ... -> top1: nblocks=615 is_compacted=1    <- WORKS
top0: nblocks=2366 is_compacted=0
pass0: prevblocks=2366 nblocks=4553 BREAK(no-progress)                         <- gives up
```

The first invocation converges properly (1,910 → 615). Later ones extend once and then
exit on `nblocks >= prevblocks`.

**Why the pack cannot reclaim, proven:** pages freed by *this* transaction carry its own
xid, and `bm25_page_recyclable()` gates on `GlobalVisCheckRemovableXid()`, which is false
for a still-running transaction. So immediately after a merge **every** candidate page is
rejected, the pack phase finds nothing reusable, and vacate+pack degenerates to *vacate
alone*: `+live_size`, no reclaim. Removing the convergence guard just let that repeat —
`121 → 223 → 326 MB`, strictly worse.

That also explains why reclaim fundamentally requires a **later transaction**, and why
attempts 1–3 (all reclaiming inside the merge's own transaction) could never work.

## Two real improvements from this attempt

Adding a pre-check so a pass **declines to vacate when nothing is recyclable** rather than
extending:

| | per-pass growth | base |
|---|---|---|
| before | ~17 MB | 35 MB |
| decline-if-nothing-recyclable | **~5 MB** | **24 MB** |

Both the growth rate and the starting size improved. Requiring `usable >= live` (enough
recyclable space for the whole segment) on top of that changed nothing further.

## Then the finding that redirects everything

Instrumenting each stage *inside* cleanup:

```
PGFTSDIAG stages: start=2115 flush=2366 merge=2366
PGFTSDIAG stages: start=3095 flush=3095 merge=3095
PGFTSDIAG stages: start=3824 flush=3824 merge=3824
```

**Within cleanup nothing grows** — `start == flush == merge` on every call after the first
(whose `+251` is legitimate pending-data folding). Yet `start` climbs **2,115 → 3,095 →
3,824** between calls.

**The growth happens outside `VACUUM` entirely.** Every fix in attempts 1–4 targeted the
vacuum path, which this shows is innocent. The leading candidate is the insert-time
opportunistic merge (`pg_fts_am.c:5325`, `bm25_merge_segments` under a conditional lock),
which would run when the lock is next free rather than at insert time — but I have not
instrumented it, so that is a hypothesis, not a finding.

## State

Reverted to the last verified-good build. **None of attempt 4's changes are in the tree** —
the decline-if-nothing-recyclable pre-check is a genuine ~3× improvement and worth
revisiting, but it targets a path that is not the cause, and shipping it would encode a
wrong mental model in the code comments.

`t/010` keeps its bounded (not zero) assertion, with a comment recording that the writer is
outside vacuum.

## Requirement status: NOT met, after four attempts

What four attempts produced: the growth is **not** in `VACUUM`; reclaim of same-transaction
freed pages is impossible by design (`GlobalVisCheckRemovableXid`); write-before-free
and in-loop extend-only are both non-negotiable; and declining to vacate when nothing is
recyclable is a real 3× win once aimed at the right path.

**The next step is one measurement, not a fix:** instrument the insert-time merge at
`:5325` — block count before/after, and whether it runs during `t/010`'s three VACUUMs —
using `$node->logfile`, which is the only route that surfaces `elog` from a TAP run. If it
is the writer, the fix is to stop *it* extending, and the decline-if-nothing-recyclable
pre-check likely applies there directly.

I have stopped rather than attempt a fifth change on a hypothesis. Docs continue to
recommend a periodic `fts_vacuum`.
