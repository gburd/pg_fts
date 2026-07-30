# pg_fts 1.3.0 vs 1.2.2 -- 2.19M Wikipedia (EC2, DB on local NVMe)

EC2 r6id.4xlarge (16 vCPU Ice Lake, 128 GB, DB + corpus on the local instance-
store NVMe, NOT EBS/tmpfs), PostgreSQL 17.10 from source, 2,188,038 Wikipedia
articles, stored `d ftsdoc` column (the recommended form).  Warm best-of-9.
Query form: `WHERE d @@@ q ORDER BY d <=> q LIMIT k` (KNN index scan);
`count(*)` via the index-native pushdown.  Term dfs: slovakia 10874 (rare),
hungary 24095 (mid), year 734881 (common).

## Headline: what 1.3.0 changes

| metric | 1.2.2 | 1.3.0 | change |
|---|---:|---:|---|
| index size (trigrams **off**, new default) | -- | **6350 MB** | new default |
| index size (trigrams **on**, old behavior) | ~21945 MB* | 21945 MB | unchanged |
| `count(*)` common (year, df 735k) | 756 ms | **3.0 ms** | **~250x faster** |
| `count(*)` mid (hungary, df 24k) | ~5 ms | **2.9 ms** | faster |
| count(*) plain-column index | bitmap fallback (~19 s) | **pushdown ~3 ms** | fixed |
| ranked rare k10 (slovakia) | 8.5 ms | 4.2 ms | same/better |
| ranked mid k10 (hungary) | 4.6 ms | 4.9 ms | same |
| ranked common k10 (year) | 31.8 ms | 27.2 ms | same |
| ranked common k100 (year) | 32.9 ms | 28.4 ms | same |

\* 1.2.2 always built the trigram tier; 21945 MB is that same tier measured on
this corpus.  It is high because this Wikipedia cut is high-vocabulary and the
tier scales with distinct-term count.

## The two big wins

1. **`trigrams = off` by default -> a 3.5x smaller index here** (6350 MB vs
   21945 MB).  The trigram tier only accelerates regex and long fuzzy queries;
   with it off those fall back to a full dictionary scan (still correct).  On a
   high-vocabulary corpus the tier dominated the index; omitting it is a large,
   free size win for the common case.  Build `WITH (trigrams = on)` for regex-
   or long-fuzzy-heavy workloads.

2. **`count(*)` on a common term: 756 ms -> 3.0 ms (~250x).**  A single plain
   term over a tombstone-free, pending-free, all-visible index is now counted
   straight from the dictionary document frequency -- no posting decode, no heap
   probe.  It also now fires for a plain-column `fts` index (the recommended
   stored-`ftsdoc`-column form); previously only an expression index got the
   pushdown, and a stored-column `count(*)` fell back to a ~19 s bitmap heap
   scan.

Ranked latency is unchanged (the ranked path did not change): pg_fts continues
to lead on rare/mid ranked latency; common-term ranked latency is still gated by
the impact-codec gap (tracked as ROADMAP P4).

## Correctness / qualification (all on EC2)

- installcheck 3/3, isolation 2/2, TAP 8/8 (63 tests, incl. the new standby
  recovery-guard assertions), fuzz `== ALL CLEAN ==`, coverage 90.4%.
- count(*) fast path proven exact: 241-check concurrent INSERT/UPDATE/DELETE/
  VACUUM churn A/B vs the seqscan ground truth -> 0 divergences; and correct
  across fresh / DELETE (tombstones) / VACUUM / UPDATE-churn / pending states.
- Managed-service guards verified: fts_merge/fts_vacuum error on a live standby
  and require index ownership; recently-dead tuples excluded from corpus stats
  (ndocs 1000 -> 500 after delete+VACUUM+REINDEX under a horizon-pinning holder).

## Method notes

- Build times (single-segment collapse, maintenance_work_mem 2 GB): trigrams-off
  283 s, trigrams-on 454 s.  Production builds leave several segments (auto-
  merge) and are faster; single-segment was used here for a clean size number.
- `count(*)` fast path requires the index be pending-free, tombstone-free, and
  the heap fully all-visible; run `VACUUM` first (this benchmark did).  On any
  other state it safely falls back to the full visibility-map count.
