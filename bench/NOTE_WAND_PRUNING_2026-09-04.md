# NOTE: why block-max WAND does not prune on this corpus (2026-09-04)

Instrumented investigation of the last big competitive gap found by the 1.5.8
5-way benchmark: a common-term ranked top-10 (`year`, df 735k = 34% of the
corpus) takes ~60-70 ms and reads ~8,100 buffers, where pg_search/Tantivy
answers the same query in 2.3 ms. Rare/mid terms are ~10 ms where competitors
are 1-2.5 ms.

**Result: three plausible fixes are DISPROVEN by measurement.** Do not spend
effort on them. The real cause is the corpus's impact distribution, and the
remaining lever is a different traversal, not a tighter bound.

## Method

Temporary counters in the WAND loop (reverted, not committed) exposed via a
`fts_diag_wand()` SQL function: blocks loaded, docs actually scored, block-skips
taken, pivot steps, plus the average block-max bound vs the average live
threshold at each skip decision, the TRUE per-block max impact (max over the
block's actual postings of `impact(tf_i, dl_i)`), and a simulated finer
granularity (max impact over each 16-posting sub-range).

Rig: EC2 r6id.4xlarge, PG 17.10, pg_fts 1.5.8, 2,188,038 Wikipedia articles
(title+body), one segment, 1421 MB index, `doclen_sidecar=on`, warm.

## Measurements

| band                | df      | blocks_loaded | docs_scored | blockskips |
|---------------------|---------|---------------|-------------|------------|
| rare `slovakia`     | 10,875  | 86            | **10,875**  | **0**      |
| mid `hungary`       | 24,097  | 190           | **24,097**  | **0**      |
| common `year`       | 734,896 | 5,743         | **670,976** | 500 (~9%)  |

The scan **scores essentially every posting** to return a top-10.

| band   | block-max bound | live threshold | TRUE block max | sub-16 max |
|--------|-----------------|----------------|----------------|------------|
| rare   | 11.3153         | 10.1048        | **11.3169**    | 10.8009    |
| mid    | 9.7011          | 8.6617         | **9.7001**     | 9.2578     |
| common | 2.3398          | 2.0174         | **2.3429**     | 2.2574     |

## What this rules out

1. **"The block-max bound is too loose because it pairs `max_tf` with `min_dl`
   (two different docs)."** DISPROVEN. The measured TRUE block max impact equals
   the current bound to 4 decimal places on every band (11.3169 vs 11.3169;
   9.7001 vs 9.7001; 2.3429 vs 2.3429). The bound is already exactly tight for
   this data, so **storing a precomputed per-block max score at build time (a
   posting-block format change) would gain nothing.** That is the expensive fix
   and it is not worth doing.

2. **"Blocks are too coarse at 128 postings."** DISPROVEN as a sufficient fix.
   Simulating 8x finer granularity (16-posting sub-ranges) lowers the max by only
   3.7-4.6% (rare 11.32 -> 10.80, mid 9.70 -> 9.26, common 2.34 -> 2.26), and in
   every band the sub-16 max is STILL ABOVE the live threshold (10.80 > 10.10;
   9.26 > 8.66; 2.26 > 2.02). Finer blocks would still prune ~nothing while
   costing more header bytes and more decode calls.

3. **"The `wantk = k*4` MVCC over-fetch depresses the threshold and kills
   pruning."** DISPROVEN. Pruning is identical at k=1, k=10 and k=100 (all three:
   190 blocks loaded, 24,097 docs scored, 0 block-skips). The threshold is also
   rising correctly -- it sits only ~12% below the block max.

## The actual cause

The block-max bound is tight AND the threshold is healthy; they are simply ~12%
apart, consistently, everywhere. That means **nearly every block genuinely
contains a document whose true impact exceeds the current k-th best score** --
the BM25 impact distribution on this corpus has a long flat plateau, so being
"in the top 128-posting block" and "beating the 10th best score" are almost the
same condition. Block-max WAND has nothing to skip. This is the known hard case
for WAND-family pruning, not a bug.

## What could actually close the gap (unproven, ordered by expected value)

- **Impact-ordered / impact-tiered postings.** Store each term's postings sorted
  by impact (or in a few impact tiers) instead of purely docid-ordered, so the
  scan can stop after the first tier once the threshold exceeds the tier bound.
  This is how engines get O(k) instead of O(df) on flat distributions. NOTE:
  `bench/NOTE_IMPACT_ORDERING.md` already recorded that a docid-ordered
  *block-skip directory* does not prune real text -- this is the stronger
  variant (reorder the postings themselves), and it conflicts with the
  docid-ordered intersection the boolean/AND/phrase paths rely on, so it likely
  means a SECOND posting layout used only for pure-ranked single-term queries.
- **MaxScore instead of WAND** for the single-term / few-term case (`fts_search_maxscore`
  already exists): with one term MaxScore degenerates similarly, so measure
  before believing it helps.
- **Early termination with a documented recall bound** (e.g. stop after scoring
  N x k candidates). Cheap and effective, but it breaks the exactness contract
  the parity harness enforces; would need to be opt-in
  (`WITH (ranked_exact = off)` or a GUC) and clearly documented.

## Practical framing

pg_fts's ranked latency on this corpus is bounded by scoring O(df) postings.
That is why it trails the Tantivy-backed engine on common terms by ~30x while
BEATING it on count (3.8 vs 16.3 ms), AND (2.5 vs 3.7 ms) and prefix, and while
shipping the smallest index of the field. Any real fix here is a posting-layout
change, not a bound or block-size tweak -- and it should be justified by a field
report, because the affected shape is "rank a term that appears in a third of
the corpus", which is a stopword-like query most applications do not issue.
