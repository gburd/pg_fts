# P0: VACUUM never completes on a delete-heavy index (found 2026-09-10)

**A `VACUUM` on an index with a few hundred thousand tombstones burns CPU
indefinitely and never finishes.** Found while qualifying sparsemap 5.5.1; it is
**not** caused by that upgrade — it is pre-existing in v1.6.0 and earlier.

This is the most serious open defect in the project and it is **not yet fixed**. Two
attempted fixes were wrong (recorded below so they are not retried).

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
