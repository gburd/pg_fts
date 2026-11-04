# CBMC proofs and the fixes they found (2026-11-03)

Current.  Records what `test/cbmc` proves, what it found in shipped code, and the
measurements behind the CHANGELOG Unreleased entries.  Harnesses and the run script are
in `test/cbmc/` (see its README); the scripts behind the numbers here are in
`bench/data_cbmc_2026-11-03/`.

## Proof run

Debian 13, cbmc 6.6.0 (minisat), r6id.8xlarge (32 vCPU, 256 GB), each proof an
independent job.  Every property ran against the shipped code (or a verbatim copy:
`check_verbatim.py`, 17 copies, all equal to the source) and against a mutant with a
historical bug planted back in, which had to fail.

| harness | shipped code | mutants caught |
|---|---|---|
| traversal: `fts_search_bmw` 2 terms x 3 docs k=1, k=2; x 4 docs k=1 | VERIFIED (89 s, 67 s, 286 s) | 1.3.0-1.15.1 pivot clamp at 3 and 4 docs |
| traversal: `fts_search_maxscore` 4 terms x 3 docs k=1 | not verified: no verdict after 70 min (`CBMC_SLOW=1`) | 1.10.0 suffix sum (1,192 s) |
| query shortcuts (Q1-Q5, <= 7-item queries) | VERIFIED | all three |
| on-page guards (6 entry points) | VERIFIED after the fixes below | 1.7.0 pd_lower, 0.3.4 clamp, 1.15.2 dictionary guard / columns / sidecar |
| FOR codec, doclen byte | VERIFIED (n = 1, 2, 3, 8; widths 65/128/255) | short buffer, exact quantisation |
| sparsemap cursor, 4 layouts | VERIFIED (C1-C3) | gap resume without its neighbour check |
| shared doclen protocol | VERIFIED (823 s) | retire ignoring readers (S1), unref also unpinning (S2) |
| block bounds, IEEE | native sweep: 11,127,520,000 cases at 10,000 corpus shapes, 0 violations | 1.15.2 BMW order: 2,845,701 violations in 222M cases |

The symbolic IEEE `harness_bound` (tf, length and block symbolic, avgdl and idf fixed)
had not finished after 90 minutes per shape and is run only with `CBMC_FP=1`; the
native sweep is the gate for that property.

## Findings in shipped code

1. **`wand_load_block` decoded FOR columns without sizing them against the block.**
   Reproduced end to end on an ASan PG 17.10 build (`e2e_w.sh`): one docid width byte of
   a full 128-posting block set from 8 to 9 or 64 with the server down.

   | width byte | 1.15.2 + main, ranked top-10 | fixed |
   |---|---|---|
   | 9  | backend abort, `Assert("ItemPointerIsValid(pointer)")` (garbage docids decoded from the block's own bytes) | returns; agrees with count(*) |
   | 12 | ERROR "could not read blocks 139..139" | returns |
   | 20 | ERROR "could not read blocks 706..706" | returns |
   | 64 | ERROR "could not open file ... (target block 673617263)" | returns |

   ASan reported nothing: the copy is palloc'd, inside an arena.  `t/003_corruption.pl`
   now checks widths 9 and 64 (ranked and count(*) agree, no error); on the 1.15.2 C
   files it fails 3 of those checks.
2. Same class: the doclen sidecar readers (no check of the gap column against
   `gapbytes`; ASan heap-buffer-overflow at width >= 9 in a standalone replay) and
   `bm25_decode_term`'s column check (reads the tf width byte one past the block when the
   docid column fills it exactly; ASan heap-buffer-overflow, 1 byte).
3. Five dictionary walks without `bm25_dict_entry_fits`; guards that formed a pointer
   past the page from an on-disk integer (CBMC pointer-overflow check).
4. **The BMW block bound one ulp low**: `idf * mtf * (k1 + 1)` vs the score's
   `(idf * (k1 + 1)) * tf`; 462 of 3M random (corpus, block) shapes in a Python replay.
   A wrong skip needs the threshold to equal the bound exactly; searches over 20,000
   random corpora (single- and two-term) found no posting scoring exactly a bound, so no
   wrong top-k is known.

The new shared column check (`bm25_for_cols_fit`) was compared with the old open-coded
check on every layout the writer produces: counts 1-128, every width 0-64 per column, v3
and v4 (`detect_equiv.c`): 35,692,800 layouts, 0 disagreements (accepted, and the same
inline-doclen detection).

## sparsemap (upstream, not reachable from pg_fts): ROADMAP I29

`smcursor_harness.c` C3x: a cursor whose left-neighbour hint is not a chunk start can make
the 5.8.4 gap resume start mid-chunk.  CBMC counterexample (layout 1, hint 16, lookup
32773) replayed natively (`smcur_cex.c`): with the cursor `false`, without `true`.  The
public API leaves such hints after add/remove without resetting the cursor in 24,168 of
300,000 random trials; 12M lookups after them gave no wrong answer (`stale_api.c`).

5. **Found by review of the fix, not by CBMC**: the first version of item 1 took the
   column count from the segment (no sidecar => three columns), so a two-column block
   in a segment without a sidecar (what 1.5.0-1.5.2's merge wrote, CHANGELOG 1.5.3) made
   the ranked cursor end the term's chain early: `t/003`'s new two-column case fails
   check 48 ("ranked still finds all 3000") on that version and passes
   on the final one, which detects the third column per block, as `bm25_decode_term` does,
   and scores a block without it at the block's minimum length (the length its bound
   assumes).  On 1.15.2 such a block read a "doclen" past the copied block.

## Cost of the fixes (`cbab.sh`)

c6id.4xlarge (Xeon 8375C, 16 vCPU), PG 18.6, 640k-row Zipf corpus (60 tokens a row), one
index with one segment, `.so` swapped: main a6938d1 vs this tree (with sparsemap 5.8.4),
plus this tree built twice (A/A).  Correctness first: for both builds, all 12 (query, k)
top-k score lists equal the exhaustive ranking (24/24).  Median of 11 timings per sample,
12 interleaved samples per build.  First run (before item 5):

| query | k | main ms | fixed ms | diff | A/A |
|---|---|---|---|---|---|
| `t10 \| t11` | 10 | 13.561 | 13.458 | -0.76% | +0.23% |
| `t10 \| t11` | 100 | 21.398 | 21.304 | -0.44% | +0.01% |
| `t40 \| t300` | 10 | 1.998 | 1.986 | -0.58% | -0.40% |
| `t40 \| t300` | 100 | 2.374 | 2.396 | +0.93% | -0.83% |
| `t10 \| t11 \| t12` | 10 | 41.058 | 40.600 | -1.11% | +0.03% |
| `t10 \| t11 \| t12` | 100 | 41.681 | 41.474 | -0.50% | +0.07% |
| `t10` | 10 | 0.191 | 0.195 | +1.83% | -1.29% |
| `t10` | 100 | 0.821 | 0.818 | -0.43% | +0.24% |
| 4-term OR | 10 | 21.694 | 21.510 | -0.85% | +0.03% |
| 4-term OR | 100 | 24.499 | 24.328 | -0.70% | +0.04% |
| `t10 & t11` | 10 | 7.023 | 7.021 | -0.03% | +0.22% |
| `t10 & t11` | 100 | 11.971 | 11.979 | +0.07% | -0.13% |

Re-run on the final code (after item 5), same host and corpus, 24/24 top-k score lists
equal to the exhaustive ranking (`cbab_final.log`; the first run is `cbab_run1.log`):

| query | k | main ms | final ms | diff | A/A |
|---|---|---|---|---|---|
| `t10 \| t11` | 10 | 13.530 | 13.623 | +0.69% | -0.37% |
| `t10 \| t11` | 100 | 21.491 | 21.648 | +0.73% | -0.29% |
| `t40 \| t300` | 10 | 2.007 | 2.005 | -0.12% | +0.25% |
| `t40 \| t300` | 100 | 2.385 | 2.405 | +0.86% | +0.06% |
| `t10 \| t11 \| t12` | 10 | 40.770 | 41.360 | +1.45% | -1.29% |
| `t10 \| t11 \| t12` | 100 | 41.602 | 42.197 | +1.43% | -1.26% |
| `t10` | 10 | 0.196 | 0.193 | -1.53% | +0.00% |
| `t10` | 100 | 0.819 | 0.818 | -0.18% | -0.31% |
| 4-term OR | 10 | 21.818 | 21.631 | -0.85% | +0.27% |
| 4-term OR | 100 | 24.567 | 24.399 | -0.68% | +0.01% |
| `t10 & t11` | 10 | 7.079 | 7.059 | -0.28% | +0.35% |
| `t10 & t11` | 100 | 12.075 | 12.123 | +0.41% | -0.42% |

No measurable cost in either run: every difference is within 1.6% and next to the A/A
spread (up to 1.3%), and the signs change between the two runs (3-term OR -1.11% then
+1.45%, single term +1.83% then -1.53%).  NOISY at the 1% level (a virtualised 16-vCPU host; a
c6id.metal was unavailable, InsufficientInstanceCapacity in us-east-2a and 2b).
