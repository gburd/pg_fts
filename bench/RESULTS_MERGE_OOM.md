# Index-build merge OOM fix — validation (2026-07-16)

## Report
A consumer stopped using pg_fts because building an index at scale OOM'd the
server in the final merge phase.

## Root cause
The BUILD path is memory-bounded (flushes a segment when the in-memory
accumulator exceeds maintenance_work_mem).  The MERGE path was NOT: both
bm25_merge_selected and the parallel bm25_merge_group_to_seg decoded EVERY
posting of EVERY term of all source segments into one in-memory BM25BuildState,
then wrote a single segment.  A full compaction of a large index therefore held
the entire index's live postings + positions in RAM at once -> OOM.

## Fix
Streaming k-way segment merge (segments are term-sorted on disk, so a merge is
a k-way merge of sorted streams): read each source's dictionary metadata only,
sweep distinct terms in sorted order, and for each term decode only that term's
postings from the segments that carry it, tombstone-filter + merge in a
per-term child memory context, write it, record small dict metadata, and free
the child context before advancing.  Peak memory: O(one term's postings + term
metadata) instead of O(all live postings).  No on-disk format change; one
term-sorted output segment per merge (coalesce-to-one preserved).

## EC2 measurement (r7i.4xlarge, PG18, 3M-doc / ~600MB index, mwm=32MB -> multi-segment build)
Instrumented the merge to log MemoryContextMemAllocated(merge ctx) peak, same
corpus for both:

| build | merge ctx peak | index size | build time | nsegments |
|-------|----------------|------------|------------|-----------|
| OLD (buffer-everything) | **2240 MB** | 579 MB | 29.5 s | 1 |
| NEW (streaming)         | **1 MB**    | 633 MB | 31.0 s | 1 |

The OLD merge buffered ~4x the on-disk index size in decoded postings/positions
(2240 MB for a 579 MB index); at the consumer's scale this grows linearly with
the index and OOMs.  The NEW merge stays flat at ~1 MB regardless of index size.
Same result (single segment, ~same size), no build-time regression (~31s).

## Correctness
- Local flake: installcheck-pg17, installcheck-pg18, tap-pg17 EXIT 0, including a
  new "Streaming merge" regression test (low mwm -> many segments, positions=on,
  VACUUM-written tombstones merged with a fresh segment, index-vs-seqscan @@@
  count parity + phrase + coalesce-to-one + ndocs tombstone-drop).
- Independent review (worker->reviewer): SOUND TO COMMIT, all items PASS under
  ASan + assertions -- parity across the k-way merge (multi-page dict,
  term-in-some-segments, prefix families), term ordering identical to
  cmp_buildterm, tombstones dropped, no use-after-free, memory bound flat.
- EC2 index parity: index-scan count == forced-seqscan count.

Instance terminated + fully cleaned up (verified).
