# Re: sparsemap 5.8.4: the read cursor's gap resume trusts an unverified `prev_offset`

**To:** pg_fts
**From:** the sparsemap maintainers
**Date:** 2026-11-04

You were right, and it is fixed in **5.8.5**, released today: tags `v5.8.5`
(C, `6be665c`), `rust-v5.8.5` (`7680bb0`, crates.io `sparsemap` 5.8.5) and
`no-rle-v5.8.5` (`735746a`), on Codeberg and GitHub.  It is a drop-in
source swap: no API, ABI or wire change.  `sm_cursor_t` is still 24 bytes
and serialized output is byte-identical to 5.8.4.

## What I confirmed

- `repro_wrong_answer.c` against the v5.8.4 files you attached (byte-identical
  to the tag): `prev_offset=16` gives `with cursor 0, without 1`, exit 1, with no
  sanitizer report.  `why.c` matches your explanation.
- Your CBMC harness (CBMC 6.9.0 here): `harness_stale_hint` fails on v5.8.4
  with your counterexample.
- The RLE-free variant had the same bug.  Your repro fails on
  `no-rle-v5.8.4` too.
- Your reachability numbers hold.  Through `sm_add_grow_cursor`, in
  9.3 million inserts, `prev_offset` was never a non-chunk-start and
  `offset` was never off a chunk start.  Only cursors kept across a
  mutation, copied, or overwritten can carry a bad hint.

## What I found besides

`sm_next_member` never checked its cursor.  It resumed from `cur->offset`
whenever `cur->start_idx <= prev_idx`, without reading the start word there.
A cursor whose offset had moved walked from mid-chunk: 595,181 wrong answers
in 845,488 lookups through mispositioned cursors.  This predates 5.8.4 (it
is the same on 5.7.0 and 5.8.3).  5.8.5 fixes it too.  pg_fts's tombstone
code calls `sm_next_member` with a cursor; in the way you describe using it
(read-only maps, cursor reset after `sm_add_many_grow`) it was not reachable.

## The fix: none of your four options

Every option you listed either breaks the ABI (1, 2), leaves the defect (3),
or loses the speedup (4).  There is a fifth, which needs no new field:
**never resume from the hint.**

- The walk starts only at chunk 0, or at `cur->offset` once its start word
  equals `cur->start_idx`.  That is the 5.8.3 trust level.
  `prev_offset` is no longer read by any lookup.
- To keep e509319's speedup, a lookup that ends in the gap before a chunk now
  caches that chunk's left neighbour.  The walk itself just stepped over that
  chunk, so it is a verified chunk start.  The next ascending lookup in the
  gap is `>=` the neighbour's start, takes the ordinary checked resume, and
  steps once.  The returned chunk does not change.
- `__sm_map_set` takes the cursor's `prev_offset` as its coalesce left-hint
  only when the cursor sits on the chunk it returned.  The coalesce path
  already re-checks the hint.

Cost: 100,000 ascending gap lookups over 20,000 chunks take 2.9 ms (5.8.3:
2,800 ms; 5.8.4 was similar).  Gap, hit, `sm_next_member` and dense per-op
timings match 5.8.4 within noise.

## Verification

- **CBMC**, your harness, all four layouts on both variants: C1, C2, C3 and
  **C3x** (any `prev_offset`) all verify.  For no-rle I regenerated the layouts
  with that build, because it encodes runs differently.
- **Teeth.** Your `mutate_sm.py` targets code that is gone.  Instead I added a
  stale-offset property: `start_idx` is a real chunk's start and `offset` is
  any 8-byte position.  It verifies on all four layouts.  A mutant without the
  start-word check fails it (checked with `--no-standard-checks`, so the
  answer assertion itself fails, not an overflow check).
- **Your native harnesses** against 5.8.5 all report 0 wrong answers:
  `repro_wrong_answer.c` (0 DIFFER), `stale_hint_api.c`,
  `stale_hint_search.c`, `stale_hint_mutation.c` (0 invalid, 0 wrong) and
  `grow_cursor_check.c`.  So do my `sm_next_member` and oracle harnesses (11M
  oracle checks).  Encodings built with and without a threaded cursor are
  byte-identical (8.8M inserts).
- **Test suites:** meson 31/31 with hegel and 29/29 ASan+UBSan on main; 29/29
  and 27/27 on no-rle.  On the Rust side, 86 cargo tests and wire-compat in
  both directions.
- **New tests** in `tests/test_cursor_gap.c`, run on every build:
  - your loop over every `prev_offset`;
  - `sm_contains` and `sm_next_member` through cursors at every offset of
    small maps.  A mismatched start word may sit anywhere; a matching one only
    at chunk starts.  Every `prev_offset` is tried.

  Each fails on 5.8.4.

## What is still true, and now documented

The `offset` check is a cheap filter, not a proof.  A payload word can equal
the recorded start, so a stale cursor can still answer wrong.  This holds
for every release, not only 5.8.4, and closing it needs state the cursor
does not have: your option 1 or 2, an ABI change.  `sm.h` now says this
plainly instead of calling a stale cursor merely slow.  It also says
`sm_add_grow_cursor` keeps its own cursor valid, and that `sm_prev_member`
ignores the cursor.

## For pg_fts

Vendor `v5.8.5` (`sm.c`, `sm.h`).  It also brings the three fixes your copy
lacks: `c6a11a3` (aligned RLE in union/intersection), the 5.8.3 small-set
misaligned-buffer fix, and the 5.8.4 `sm_add_range` over-read fix.  Your
CBMC harness runs unchanged against it.  `mutate_sm.py` needs a new target;
removing the start-word check in `__sm_get_chunk_offset` is the meaningful
one now.

Thanks for the report.  It came with a proof, a repro, a reachability study,
and a list of fixes priced out, which made it fast to act on.
