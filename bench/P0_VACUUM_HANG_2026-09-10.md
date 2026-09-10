# P0: VACUUM never completes on a delete-heavy index (found 2026-09-10)

**A `VACUUM` on an index with a few hundred thousand tombstones burned CPU
indefinitely and never finished.** Found while qualifying sparsemap 5.5.1; it was
**not** caused by that upgrade — pre-existing in v1.6.0 and earlier.

**STATUS: ROOT-CAUSED AND FIXED, qualified at scale.** There were **two** independent
sites, both the same mistake in different places, and the first fix only exposed the
second. Measured after the fix: the VACUUM that consumed 4h39m of CPU without
finishing now completes in **393 s**, with results identical to sequential-scan
ground truth. Full qualification in
`bench/data_p0_2026-09-10/qualification.log`:

```
start live=1,501,458 nseg=1
VACUUM rc=0 393s | year idx=504368 seq=504368 OK
del%4 deleted=375,674 VACUUM rc=0 270s live=1,125,784 | year 378037/378037 OK | slovakia 5605/5605 OK
del%3 deleted=374,809 VACUUM rc=0 178s live=750,975   | year 251902/251902 OK | slovakia 3751/3751 OK
fts_vacuum=135s size=5716 MB
FINAL year 251902/251902 MATCH_OK server=1
```

---

## Reproduction

EC2 r6id.4xlarge, PostgreSQL 17.10, pg_fts 1.6.0, `maintenance_work_mem=1GB`,
2,188,038 Wikipedia articles indexed on a stored `ftsdoc` column, `nsegments=1`.

```sql
DELETE FROM docs WHERE id % 7 = 0;   -- 312,166 rows
VACUUM docs;                          -- never returns
```

Observed after **4h39m**:

| | |
|---|---|
| process state | `Rs` — running, on CPU, not blocked |
| CPU consumed | `04:36:43` (≈100% of wall-clock) |
| live rows | 1,875,872 (the DELETE committed fine) |
| `nsegments` | 1 |
| `perf` (1K samples) | **99.75% `__sm_get_chunk_offset`**, nothing else above 1% |

A second run reproduced it identically (97.65% in the same symbol at 15 minutes).

## The call path, from gdb

`perf` callchains were unusable without frame pointers; `gdb -batch -ex "bt"` on the
live backend gives it definitively:

```
#0  __sm_get_chunk_offset
#1  __pg_bm25_sm_contains
#2  bm25_merge_segments_streaming
#3  bm25_merge_selected
#4  bm25_compact_to_one
#5  bm25_vacuum_compact
#6  bm25_vacuumcleanup
#7  vac_cleanup_one_index
#8  heap_vacuum_rel
```

So: autovacuum cleanup → compact-to-one → streaming merge → per-posting tombstone
membership test.

## Why it is quadratic

`bm25_merge_segments_streaming` iterates **terms** in sorted order and, within each
term, that term's postings in ascending docid order. The tombstone test is
`sm_contains_cached` (`pg_fts_am.c:3404`), the 8-way MRU cache.

The docid sequence is therefore **not globally monotonic**: it ascends within a term
and resets at every term boundary. A cursor or small MRU cache is defeated by that
reset, so each lookup re-walks the chunk chain from the head.

Order of magnitude on this corpus: a 2.19M-docid space is ~1,068 sparsemap chunks,
and the index has **7,357,921 terms**. A head-walk per posting across millions of
postings is not a slow path, it is a non-terminating one.

This is the *same pathology* ROADMAP item 9 records for the ranked scan — where the
MRU cache "degenerated to an O(chunks) head-walk once an ascending scan ran past its
eight cached chunks", fixed in 1.4.1 by the forward-resume cursor and measured 24 s →
2.5 ms. **The merge path never got an equivalent fix**, and item 9's remaining TODO
was exactly to test it under delete pressure. It was never completed (see
`bench/RESULTS_SPARSEMAP_2026-09-08.md`, where the rig's own control variable turned
out not to exist). This is what that test would have found.

## Two attempted fixes, both WRONG — do not retry

1. **Swap `sm_contains_cached` for a forward-resume `sm_cursor_t`, reset per term.**
   Compiled clean, passed the whole local gate (installcheck PG17/18, TAP, alloc,
   ascii, fuzz), and **did not fix the hang** — still 97.65% in
   `__sm_get_chunk_offset` after 15 minutes. The per-term reset reproduces exactly
   the behaviour it replaced. Resetting ~7.4M times is no better than an MRU cache
   that misses.
2. **Hoist a stray `sm_cursor_t ccur = SM_CURSOR_INIT;` out of a loop in
   `bm25_bulkdelete`** (it was declared *inside* an ascending walk, so it reset every
   iteration). This is a **genuine latent inefficiency and worth fixing on its own
   merits**, but it is not this bug: gdb shows the hot path is
   `bm25_merge_segments_streaming`, not `bm25_bulkdelete`.

Lesson: both attempts passed the full local gate, because the gate has no
delete-heavy-at-scale case. Local green means nothing for this class of defect.

## The fix that is likely correct (not yet implemented)

Use **`sm_contains_many`** — the batched left-to-right sweep already used by the
ranked scan (`pg_fts_am_scan.c:286`), documented there as `O(chunks + n)` and
**order-independent across calls**, so a per-term docid reset costs nothing.

Shape: for each `(source, term)`, collect that term's docids into an array (the merge
already decodes them into `post[]`), call `sm_contains_many` once to get a parallel
result array, then consume the flags in the existing loop. Per term the cost becomes
one sweep instead of `np` head-walks.

Open questions before implementing:
- Does the streaming merge have a natural place to hold a per-term scratch array, and
  what bounds its size (`mt->df` for that term)?
- `sm_contains_many` takes a `size_t n` and writes `n` results — confirm the exact
  signature and whether it requires sorted input (postings are already
  docid-ascending within a term, so probably satisfied either way).
- Item 9's earlier measurement showed the batched filter is **not a regression** at
  zero tombstone density (three arms within 0.9%, byte-identical output), which is
  reassuring for the non-delete case.

## Severity

**P0.** A user who deletes a meaningful fraction of a large indexed table and then
vacuums gets a backend pinned at 100% CPU forever. Autovacuum will retry it. There is
no error, no log line, and no completion — the index simply never gets cleaned, which
also means **space is never reclaimed**.

That last point matters: this is a plausible cause of the field team's outstanding
`pg_fts-bug-vacuum-merge-do-not-reclaim-bloat-2026-08-09` report, whose original text
I no longer have. Their production index is 2.87M docs with deletes — the same shape
as this reproduction. **Ask them whether their VACUUMs complete.**

## Release implication

sparsemap 5.5.1 is vendored, qualified, and green on the full local gate, and its one
substantive change (`__sm_append_data` returning `bool` with `SM_WARN_UNUSED`, so the
eight call sites must handle ENOSPC) is a genuine hardening of a path pg_fts uses:
`sm_add_many_grow` → `__sm_add_c` → `__sm_map_set` → `__sm_append_data`, where 5.5.0
had an **unchecked** append. Our grow-retry loop depends on ENOSPC being signalled
rather than the buffer overflowing.

**But cutting a release advertising a robustness improvement while sitting on a P0
VACUUM hang would be indefensible.** Fix this first, then ship both together.

---

# ROOT CAUSE AND FIX (2026-09-10)

## One mistake, two sites

Both sites made the same error: **probing the tombstone sparsemap in a pattern that
defeats every acceleration structure sparsemap offers**, turning each membership test
into a walk of the chunk chain from the head. With ~1,068 chunks on a 2.19M-docid map
and millions of probes, that product does not terminate in practical time.

Fixing the first site did not fix the bug — it moved the `gdb` stack to the second.
That is why the earlier attempts appeared to fail.

### Site 1 — `bm25_merge_segments_streaming` (the merge/compaction path)

Reached by `VACUUM` → `bm25_vacuumcleanup` → `bm25_vacuum_compact` →
`bm25_compact_to_one` → `bm25_merge_selected`.

The loop walks **terms** in sorted order, and each term's postings ascend from a low
docid. So the docid sequence reaching the tombstone map **resets at every term
boundary** — millions of times. Neither `sm_contains_cached` (the 8-way MRU cache
originally used here), nor a forward-resume `sm_cursor_t`, nor even the batched
`sm_contains_many` survives that: all three pay an `O(chunks)` startup *per term*.

**Fix: decode the sparsemap once per source into a dense bitmap.** The map is
read-only for the whole merge, so `merge_source_open` now walks it a single time with
`sm_next_member` (`O(tombstones + chunks)`, paid once) into a flat bit array, and the
inner loop tests each posting in **O(1)**.

Sizing subtlety worth recording, because I got it wrong first: the bitmap must be
sized by **`sm_maximum(map)`**, not by `seg->ndocs`. A docid is
`heap_block * MaxHeapTuplesPerPage + offset` (`bm25_tid_to_docid`), i.e. a *sparse
global address*, unrelated to a segment's live-doc count. Sizing by `ndocs` compiles,
passes the entire local gate, and **silently drops most tombstones** — a correctness
regression caught by reading the docid encoding rather than by any test.

### Site 2 — `bm25_bulkdelete` (the per-index delete path)

Reached by `VACUUM` → `lazy_vacuum_all_indexes` → `vac_bulkdel_one_index`.

Here a cursor *was* used, but `sm_cursor_t ccur = SM_CURSOR_INIT;` was declared
**inside** the walk, so it was reset on every iteration and each `sm_contains` restarted
from the head. The enclosing walk (`sm_next_member`) is monotonically ascending, which
is exactly the cursor's contract, so the cursor was correct in intent and defeated by
its own scope.

**Fix: hoist the declaration out of the loop** and reset it once immediately before.
One line moved.

## Why the local gate never caught either

`installcheck`, TAP, alloc, ascii and fuzz all passed on the unfixed code, and passed
on **two wrong fixes**. None of them deletes a large fraction of a large indexed table
and then vacuums. Local green is not evidence for this class of defect; only the
at-scale run is.

That is also the honest reason this survived to v1.6.0: ROADMAP item 9's remaining TODO
was precisely "quantify the merge path under a delete-heavy workload", and that test
was never completed (see `bench/RESULTS_SPARSEMAP_2026-09-08.md`, where the rig's own
suppression control turned out not to exist in our source).

## Attempts that did not work, kept so they are not retried

1. **Forward-resume cursor reset per term** in the merge loop — still 97.65% in
   `__sm_get_chunk_offset` after 15 min. ~7.4M resets reproduce exactly the miss
   pattern of the MRU cache it replaced.
2. **Batched `sm_contains_many` per term** — the stack confirmed the call was in
   effect, and it still hung. `sm_contains_many` is `O(chunks + n)` *per call*;
   batching helps within a term but the per-call `O(chunks)` startup times millions
   of terms is the whole cost. This is the attempt that made the mechanism obvious.
3. Fixing site 2 alone, early on, while the profile was still dominated by site 1 —
   correct change, invisible effect, discarded as "wrong function". It was needed too.

## Field implication

A VACUUM that never completes never reclaims space, with no error and no log line.
This is a plausible cause of the outstanding
`pg_fts-bug-vacuum-merge-do-not-reclaim-bloat-2026-08-09` report from the field team —
their index is 2.87M docs with deletes, the same shape as this reproduction. **Worth
telling them explicitly that this is fixed and asking whether their VACUUMs were
completing.**
