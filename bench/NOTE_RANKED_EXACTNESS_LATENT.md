# Ranked-exactness: the `wand_skip_block` over-skip is real but LATENT (2026-07-30)

Validated on EC2 (r6id.4xlarge, PG17.10, DB on local NVMe), real 2.19M-article
Wikipedia, an 8-segment `fts` index (autovacuum off so segments persist), the
exact queries + counts from `RESULTS_P1_P4.md` (year=734881, hungary=24095,
slovakia=10874, slovakia&hungary=3059).

## What was tested

Two genuinely distinct builds of `pg_fts_am_scan.c`, everything else identical:

- **BUGGY** = shipped 1.2.2 (`fts_search_bmw`: when `blocksum <= threshold`,
  `wand_skip_block(&cursors[0])` -- advances cursor[0] to the START of its next
  128-block).
- **FIXED** = seek every cursor at-or-before the pivot to `pivot_docid + 1`
  (skips exactly the set blocksum proved cannot win).

For year/hungary/slovakia (k=10 and k=100) and the AND queries, compared the
index KNN top-k (`WHERE d @@@ q ORDER BY d <=> q LIMIT k`) against a brute-force
seqscan score sort, counting **genuine misses** = docs in the brute-force top-k
that the index dropped AND whose true distance is strictly better than the
index's worst returned (boundary ties excluded).

## Result

**Genuine misses = 0 on BOTH builds, every query, k=10 and k=100.** The index's
worst-returned distance equals the brute-force k-th distance in every case. A
rank-by-rank distance comparison of the top-500 also matches between the two
builds (the 498/500 "divergences" seen when adding `, id` to the ORDER BY are a
tie-break artifact -- year has large equal-distance bands, so index vs seqscan
pick different tied docs at each rank; the FIXED build shows the identical 498,
confirming it is not the bug).

## Why the bug is latent

The over-skip in `wand_skip_block` strands the tail of cursor[0]'s current block
-- docids **> pivot** that blocksum never bounded. The sub-agent's worked
counterexample needs a true top-k doc living in cursor[0]'s segment at a docid
that another cursor's block *also* covers, i.e. **densely interleaved segment
docid ranges**.

pg_fts never builds that layout. Each segment is produced by a build flush (or
an oversized-doc insert) that consumes documents in **TID order**, and
`docid = blk*MaxHeapTuplesPerPage + off` is monotone in TID -- so every segment
owns a **contiguous, non-overlapping docid range**. During a single-term scan
the per-segment cursors therefore cover disjoint contiguous ranges and interleave
only at range boundaries, never densely. The docids cursor[0] over-skips are its
own segment's, no other cursor holds them, and they were correctly pruned. The
unsound branch fires but drops nothing.

The original "both v2 and v4 inexact" note in `RESULTS_P1_P4.md` was measured
against the **v0.2.0** tag; the ranked scan path was substantially reworked
between v0.2.0 and 1.2.x (the v1.1.6/v1.2.0 ORDER-BY-completeness fix, the
adaptive-k growth, the WAND/MaxScore split). Whatever produced the v0.2.0
divergence is not reachable on current HEAD with this build layout.

## Decision

Keep the FIXED code (seek-past-pivot) as **defense-in-depth**: it is provably
exact (skips exactly `{docid <= pivot}`, all proven non-winners), provably
terminating (global min docid strictly increases >= 1 per fire), and has the
same asymptotic cost -- it removes an unsound-in-the-abstract branch with no
downside. But because the bug is **not field-reachable** in pg_fts's
contiguous-docid-range segment layout:

- it is **not** a correctness release blocker,
- it needs **no** reindex note, and
- ship it folded into the next routine C-only release, gated by the standard
  suite -- NOT rushed as an exactness hotfix.

The P4 impact-quantized-postings work is therefore **no longer blocked** by a
pre-existing exactness bug (there is none reachable). P4 remains a format change
requiring the mandatory in-place upgrade path.
