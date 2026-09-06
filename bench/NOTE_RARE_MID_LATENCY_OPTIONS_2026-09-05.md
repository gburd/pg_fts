# Improving rare/mid ranked latency without losing our design wins (2026-09-05)

Written after measuring where rare/mid ranked time actually goes. One option is
already implemented and shipped; the rest are ranked by expected value against
the constraint that we keep what we are good at.

## The design properties any fix must NOT damage

1. **Smallest index in the field** (1421 MB) — from the doclen sidecar +
   `positions=off` by default.
2. **Exact top-k**, enforced by the parity harness on every release.
3. **Fast count / AND / phrase / prefix** — these need **docid-ordered**
   postings, because they are docid intersections. This is the constraint that
   kills most "reorder the postings" ideas.
4. **No on-disk format break** — dual-read or nothing; a forced REINDEX is a
   release blocker.
5. **Concurrency-safe** — A1-race guards, single-chunk `rd_amcache`.

## The hard floor: why "score fewer postings" is not available

A single-term top-k needs the k largest `impact(tf_i, dl_i)`. Impact depends on
BOTH tf and doclen; in a docid-ordered posting list neither is ordered, so no
bound can exclude a run of postings without examining them. Measured
confirmation: block-max WAND takes **0 block-skips** on rare and mid
(`NOTE_WAND_PRUNING_2026-09-04.md`), and the block-max bound is already exactly
equal to the true per-block max — it simply sits ~12% above the live threshold
everywhere because the impact distribution is a flat plateau.

**So for rare/mid the lever is per-posting cost, not posting count.** Everything
below follows from that.

## Cost breakdown (measured, rare term `slovakia`, df 10,875)

| component | cost |
|---|---|
| plain `@@@` count (posting scan + tombstones, no scoring) | 2.35 ms |
| full ranked top-10 | 10.2 ms (1.5.8) |
| => ranking overhead | **~7.9 ms over 10,875 postings = ~730 ns/posting** |

730 ns/posting is ~1000x more than the arithmetic requires, so essentially all of
it was doclen gathering.

---

## 1. DONE — decode only the covering block, not the whole sidecar page

**Shipped in this run.** 1.5.8 decoded the entire sidecar page (~31 blocks,
~4,000 doc entries) to answer one lookup. A rare term scattered over 2.19M
docids touches nearly every sidecar page, so scoring 10,875 postings cost ~2.2M
doc-decodes — a ~200x amplification. Now we walk block *headers* (no FOR-unpack)
to find the covering 128-doc block and unpack only that.

- rare k10 **10.2 -> 6.05 ms (1.7x)**; count/AND/prefix unchanged; parity PASS.
- No format change, no REINDEX. Touches only the read path.
- Mid is ~flat (24k postings are dense enough to already share blocks) — this is
  specifically a sparse/scattered-term win.

## 2. RECOMMENDED NEXT — keep the whole sidecar hot per scan when it is small

The remaining per-posting cost is: directory binary search + a page read + a
128-entry FOR-unpack, per block crossed. For a scattered rare term that is still
~1 block-decode per ~20 postings.

The sidecar for a segment is **~9 bytes/doc** — 2.19M docs is only ~20 MB, and
for the rare/mid case we are already touching most of it. A bounded LRU of
*decoded blocks* (not whole pages) on the cursor — say 64-256 blocks, 8-32 KB —
would make repeat visits free and cost nothing for a dense term that never
revisits.

- Expected: recovers a further chunk of the ~3.7 ms rare-term overhead.
- Risk: low. Read-path only, no format change, bounded memory, no effect on
  count/AND/prefix.
- Must respect: allocate per-scan (not `rd_amcache` multi-chunk — that was the
  1.5.5 crash), and keep the A1 page-validity guards.

## 3. WORTH MEASURING — skip the sidecar entirely for small-df terms

For a term whose df is small relative to the segment, gathering doclens
one-block-at-a-time is worse than one sequential pass. A threshold rule ("if
df < X, bulk-load the segment's doclens once") would flip rare terms onto the
cheap path. We already have `bm25_doclens_load` (the merge uses it).

- BUT: 1.5.4-1.5.7 did exactly this unconditionally and it was a ~18 ms/scan
  disaster on 2.19M docs. The whole point of the page directory was to stop it.
  So this is only viable with a **df-based threshold measured on real data**, and
  the crossover may not exist (bulk load = ~547 pages; a rare term already
  touches ~544). Measure before implementing.

## 4. VIABLE, BIGGER — a per-posting doclen column for small-df terms only

Keep the sidecar (the size win) for the bulk of the vocabulary, but for terms
below a df threshold **also** store the inline doclen column in their posting
blocks. Rare terms then score with zero sidecar lookups (inline is a couple of
instructions), while common terms — which dominate index size — stay sidecar-only.

- Size cost: bounded by choice of threshold. Zipf means most *terms* are rare but
  most *postings* are in common terms, so "inline for df < 1000" adds little
  bytes while covering the majority of distinct terms.
- Keeps: docid ordering (so count/AND/phrase/prefix untouched), exactness,
  smallest-index-in-class.
- Cost: an on-disk change to posting blocks -> needs the dual-read discipline
  (the decoder is already self-describing from `bytelen`, which is exactly the
  mechanism that made v3/v4 mixed segments work — so this is more tractable here
  than in most codebases).
- This is the highest-value option that does not compromise anything, and the
  self-describing decoder makes it a MINOR release, not a REINDEX.

## 5. REJECTED — impact-ordered / impact-tiered postings

Would give true O(k) ranked scans (this is how Tantivy-class engines win), but it
**breaks docid ordering**, which count/AND/phrase/prefix intersection depends on
— our differentiators. Would require a SECOND posting layout used only for
pure-ranked single-term queries: roughly doubling posting bytes (losing the
smallest-index win) and a large amount of new code. Also already partly explored:
`NOTE_IMPACT_ORDERING.md` recorded that a docid-ordered impact *directory* does
not prune real text.

Revisit only if a field report shows ranked latency is blocking adoption.

## 6. REJECTED — early termination / approximate top-k

Cheap and very effective (stop after N*k candidates), but it **breaks the exact
top-k guarantee** the parity harness enforces and that we advertise. Only
acceptable as an explicitly opt-in, clearly-documented mode
(`WITH (ranked_exact = off)` or a GUC), never as a default.

## 7. NOT A FIX — tighter block-max bound / smaller blocks / less over-fetch

All three measured and **disproven** in `NOTE_WAND_PRUNING_2026-09-04.md`: the
bound already equals the true block max; 16-posting granularity still sits above
the threshold; pruning is identical at k=1/10/100. Do not spend effort here.

## Suggested order

1. (done) block-granular decode — 1.7x on rare.
2. Decoded-block LRU on the cursor (option 2) — low risk, read-path only, measure.
3. Measure the df crossover for option 3 before writing any code.
4. If rare/mid still matters after 2-3, do option 4 (inline doclen for small-df
   terms) as a MINOR release using the self-describing decoder.

Note the honest ceiling: even at zero doclen cost, rare/mid would be ~2.4 ms
(the plain `@@@` count floor) — i.e. roughly at pg_search's 2.1-2.2 ms. So
options 1-4 can close the rare/mid gap almost entirely. The **common** band is a
different problem (posting-scan bound + we stem and pg_search does not) and is
not addressed by any of this.

---

# OUTCOMES (measured 2026-09-06, 2.19M single-column Wikipedia, r6id.4xlarge)

## Option 1 — block-granular decode: DONE, 1.7x on rare
Shipped. rare k10 10.2 -> 6.05 ms. See RESULTS_5WAY_159.

## Option 2 — share the resident decoded block across a query's cursors: DONE
Reframed during implementation. The original idea (an LRU of decoded blocks) is
POINTLESS for single-term ranked: the WAND visits a cursor's docids monotonically
ascending, so a sidecar block is entered once and never revisited -- an LRU has
nothing to hit.

The real duplication is ACROSS CURSORS. Each (term, segment) has its own
BM25DoclenCursor, but the scoring loop is
    for i in cursors: if cursors[i].docid == pivot: score += contrib(cursors[i])
so for an N-term query every cursor at the pivot looks up THE SAME docid -- and
with per-cursor resident blocks that decoded the same sidecar block N times.

Fix: hoist the resident block into a per-SEGMENT slot (BM25DoclenResident) shared
by all of that scan's cursors for that segment. The 2nd..Nth lookup of a docid is
then a pure in-memory binary search.

Measured A/B (same host, same index, medians):

| query        | per-cursor resident | shared resident | change |
|--------------|--------------------|-----------------|--------|
| 1-term rare  | 6.02 ms            | 6.15 ms         | flat (expected: 1 cursor) |
| 1-term mid   | 10.83 ms           | 11.06 ms        | flat |
| **2-term OR**| **6.17 ms**        | **4.27 ms**     | **1.44x** |
| **3-term OR**| **10.95 ms**       | **6.71 ms**     | **1.63x** |

The win grows with term count, exactly as the mechanism predicts. Parity PASS on
all five shapes (single, AND, OR, k=10 and k=100). No format change.

## Option 3 — df-threshold bulk-load fast path: REJECTED by measurement
The premise was that for a small-df term, one sequential bulk load might beat
many per-block decodes. Measured ranked k10 across a df spectrum on the same
index:

| term       | df      | ranked k10 | us/posting |
|------------|---------|-----------|------------|
| bratislava | 2,560   | 2.35 ms   | 0.92 |
| zurich     | 4,225   | 3.71 ms   | 0.88 |
| slovakia   | 10,875  | 5.92 ms   | 0.54 |
| vienna     | 18,927  | 9.74 ms   | 0.51 |
| hungary    | 24,097  | 10.80 ms  | 0.45 |
| berlin     | 36,776  | 13.51 ms  | 0.37 |
| paris      | 66,826  | 17.10 ms  | 0.26 |
| city       | 397,793 | 37.6 ms   | 0.09 |
| year       | 734,896 | 55.9 ms   | 0.08 |

Cost is ~linear in df with **no fixed floor**: the smallest term already runs at
2.35 ms, which is the plain `@@@` count floor for that df. A bulk load reads ~547
sidecar pages regardless of df -- strictly MORE work than bratislava's current
2.35 ms. **There is no crossover; the page directory already wins at every df.**
Do not implement this. (This is why the plan said "measure before writing code".)

## Net effect of this release on rare/mid
rare 10.2 -> 6.05 ms (1.7x, option 1); multi-term 1.44-1.63x (option 2); the
per-posting floor is now the posting scan itself, not doclen gathering.
