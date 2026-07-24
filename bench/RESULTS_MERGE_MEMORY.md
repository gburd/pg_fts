# Merge-phase memory bound (1.0.8)

Field report `pg_fts-bug-1.0.6-parallel-recommended-config-still-oom-2026-07-24`:
a 1.9M-doc / 19GB high-vocabulary email corpus still exceeded a 30GB budget and
had its parallel worker SIGKILLed in the merge phase, at the recommended
mwm=2GB / workers=4 config. Nine attempts, nine failures.

## Root cause

The 1.0.6 flush-budget ceiling bounds the SCAN phase only. The MERGE phase held
two vocabulary-proportional structures, both unbounded by maintenance_work_mem:

1. **Input** (`merge_source_open`): each input segment's ENTIRE dictionary was
   loaded into memory, and the final reduction opens ALL segments (up to 128) at
   once => the sum of all input vocabularies resident at once.
2. **Output** (`bm25_merge_segments_streaming`): the whole MERGED vocabulary
   accumulated in `out[]` + `bs->terms[]` + `dpost[]`/`doff[]` before the
   dictionary was written.

For code/quoted-text-heavy email bodies (tens of millions of distinct terms)
each is multi-GB regardless of maintenance_work_mem -- matching the reporter's
"clean for hours, then grows once blocks_done freezes (= merge)" symptom.

The SIGKILL with `oom_kill=0` / no kernel OOM is consistent with the parallel
worker's allocation being refused (or the postmaster reaping a worker that hit
a limit): bounding the allocation removes the condition regardless of which
mechanism raised the signal.

## Fix (memory-only; no on-disk format change, no REINDEX)

- Input side is now a page-at-a-time forward cursor (`merge_source_load_page` /
  `merge_source_advance`): ~one dict page per source resident, not the whole
  segment vocabulary.
- Output dict metadata is spilled to a temp `BufFile` (`DictSpill`) and streamed
  back into the (refactored) `bm25_write_dictionary_iter`; the merged vocabulary
  is never fully in memory. The trigram writer (`bm25_write_trigrams_iter`) is
  fed the rewound spill instead of a resident `bs->terms[]`.

## Measured

Peak build backend RSS (high-vocabulary synthetic corpus, mwm=8MB, serial):

| docs | old   | new   |
|------|-------|-------|
| 60k  | 495MB | 268MB |
| 120k | 871MB | 423MB |

Old slope ~376MB per 60k docs (vocabulary-proportional, the fatal one); new
slope less than half, and the two dominant merge structures are now bounded.
Build time did not regress (40k: 24.2s -> 20.9s).

Isolated merge-context peak (excludes shared_buffers), which is now dominated by
the one remaining O(vocabulary) structure, the trigram->term-ordinal map:

| merged terms | merge-ctx peak |
|--------------|----------------|
| 1.2M         | 110MB          |
| 2.4M         | 181MB          |

=> ~59MB per 1M merged terms. Projecting to the field corpus, even a 50M-term
merged vocabulary is under ~3GB for the final (single-backend) reduction --
comfortably inside a 30GB budget, versus the old code's many-GB-per-structure.
The trigram accumulator was therefore left in memory (bounded well enough at
field scale; spilling it too was not needed -- confirmed by measurement, not
assumed).

## Verification

- Reviewed worker->reviewer: no correctness bug; identical sorted term stream,
  matching spill write/read formats, dict-order == trigram-ordinal invariant
  (guarded by a debug Assert), unchanged on-disk format.
- Full gate green (PG17/18 installcheck + TAP, check-alloc, check-ascii, fuzz).
