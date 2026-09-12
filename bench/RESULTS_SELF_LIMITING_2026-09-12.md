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
