# Build non-convergence root cause (field attempts 15-21): qsort in flush, not merge

Reproduced on EC2 (r7i.8xlarge, PG18, 1.97M-doc realistic heavy-tail high-vocab
corpus, real english words + doc-unique tokens). Serial build (workers=0),
pg_fts 1.1.5. Symptom matches the field exactly: phase='building index',
backend R at ~100% CPU, read ~330MB/s but write=0, nsegs frozen, ZERO
"merging N of M" log lines for 20+ min.

gdb backtrace of the real build backend (repeated samples, consistently):

  __memcmp_evex_movbe
  cmp_buildterm            pg_fts_am.c:183
  pg_qsort (recursive)
  bm25_build_flush_segment pg_fts_am.c:468 / 484   <-- qsort(bs->terms, bs->nterms, cmp_buildterm)
  bm25_build_callback      pg_fts_am.c:557/526
  heapam_index_build_range_scan
  bm25_scan_and_build      pg_fts_am.c:3446
  bm25_build               pg_fts_am.c:3734

So the build is NOT stuck in the merge (the "merging N of M" never logs because
the merge is never reached). It is stuck in bm25_build_flush_segment's
qsort(bs->terms, bs->nterms, sizeof(BuildTerm), cmp_buildterm) -- sorting a
flushed segment's term array. The heavy 330MB/s read is the heap scan feeding
bm25_build_callback; the CPU sink is the per-flush term qsort.

HYPOTHESES (for the fix investigation):
1. Enormous nterms per flush on a high-vocabulary corpus (millions of distinct
   terms per 1-2GB flush) -> O(N log N) qsort with a slow cmp (memcmp of term
   bytes) is genuinely minutes, and it happens on EVERY flush. Total build =
   (#flushes) x (per-flush qsort). Could be "very slow but finite", presenting
   as non-convergence within any patience window.
2. qsort worst-case: cmp_buildterm ties (equal-prefix terms) could drive
   glibc/pg_qsort toward O(N^2) on adversarial input (many shared prefixes ->
   the id-token vocabulary has huge shared prefixes like 'id12345...').
3. cmp_buildterm itself (pg_fts_am.c:183) may be O(termlen) per compare with
   long terms; combined with N log N compares on millions of terms = huge.

LIKELY FIX DIRECTION: the flush should not need a full qsort of all terms if the
build hash/accumulation kept them sorted or radix/bucketed; or replace qsort
with a radix sort on the term bytes (terms are short byte strings); or reduce
per-flush nterms. Needs measurement of nterms-per-flush and a cmp count to
confirm which of 1/2/3 dominates, then the matching fix. This is SEPARATE from
the ORDER BY <=> truncation bug (fixed in 1.1.6) and the merge fixes (1.1.0-1.1.5).
