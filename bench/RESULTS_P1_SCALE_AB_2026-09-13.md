# P1 at-scale A/B: does the recyclable-room fix matter at 1M docs?

**Date:** 2026-09-13
**Host:** r6id.4xlarge (16 vCPU / 8 physical cores / 128 GB), local NVMe, PG 17.10
**Arms:** `base` = HEAD (no fix) · `fix` = HEAD + `bm25_have_recyclable_room`
**Corpus:** 1,000,000 docs, 200k-term vocabulary, 60 terms/doc
**Autovacuum:** ON and aggressive (`naptime=10s`, `insert_threshold=1000`,
`scale_factor=0.02`) — the point is *unattended* maintenance
**Raw:** `bench/data_p1scale_2026-09-13/p1_{base,fix}.log`

## Result: no difference between the arms

| phase | base | fix |
|---|---|---|
| build + vacuum | 512 MB | 508 MB |
| 5× repeated `VACUUM (INDEX_CLEANUP on)`, nothing changed | **511 MB flat** | **509 MB flat** |
| 6 rounds of +50k insert / delete-1-in-7, **no manual maintenance** | **875 MB flat** | **875 MB flat** |
| after `DELETE > 500k`, then 12 cleanups | **875 → 106 MB** | **875 → 106 MB** |
| parity (`fts` vs regex ground truth) | — | **129 = 129** |

## What this means, stated plainly

**The P1 growth does not reproduce at 1M docs on the unfixed code.** Repeated cleanup is
already flat on `base`, sustained churn is already flat on `base`, and a big delete already
reclaims 8.3× on `base`. There is no bug at this scale for the fix to fix.

**So the fix is NOT validated at scale.** It is validated at small scale by `t/010`
(base 35 → 52 → 69 MB versus fixed 18/18/18, and the after-delete reclaim to 4 MB), and it
is proven not to *harm* anything at 1M docs — same sizes, same reclaim, parity exact — but
I have not demonstrated that it matters on a production-shaped index.

## Requirement status

The user requirement — *incrementally vacuumable while online, makes progress, no operator
scheduling, no downtime* — **is met at 1M docs, and was already met by the shipped code.**
Unattended autovacuum alone held the index flat through six churn rounds and reclaimed
875 → 106 MB after a large delete, with queries served throughout and answers exact.

That is a better outcome than the P1 diagnosis implied, and it means the earlier
"a periodic `fts_vacuum` is still recommended" wording was calibrated to the small-scale
`t/010` behaviour rather than to a measured production-scale case.

## What is still unknown

The field report that started this (2.87M docs, high vocabulary, delete-heavy) is at ~3×
this scale with a different document shape. This run does **not** cover it. The honest
position is: no reproduction at 1M docs, a real small-scale defect fixed, and the
production-scale question still open pending either a bigger run or the field team's
original report text.

## Harness notes (both cost a re-run)

* `%%` in a non-printf shell script reached SQL literally → `LOAD FAILED`.
* `psql -v b=... -c "... :'b' ..."` does not expand inside `-c`; the per-round row-count
  assertion caught it (`ROUND 1 INSERT WRONG: 0`) instead of recording a false flat line.
* The match operator is `@@@`, not `@@`. The first parity attempt silently produced an
  empty result and printed `parity: fts= regex=129`; re-run by hand gave 129 = 129.
  An empty value should have failed the harness, not been printed.
