-- pg_stat_user_indexes visibility: every query path that reads the bm25 index
-- to answer a query must register an index scan (idx_scan) and the index entries
-- it produced (idx_tup_read).  For each path we reset stats, force the plan,
-- run one query, flush, and read the counters.  The dataset is fixed so the
-- counts are deterministic: 'quick & fox' matches 'quick brown fox' and
-- 'quick fox runs' -- exactly half of the 4000 rows = 2000.
SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;

CREATE TABLE ss (id int, body text);
INSERT INTO ss SELECT g, (ARRAY['quick brown fox','lazy dog','quick fox runs','brown bear'])[1+g%4]
  FROM generate_series(1, 4000) g;
CREATE INDEX ss_fts ON ss USING fts (to_ftsdoc(body));

-- 1) Bitmap Index Scan (the common @@@ path); idx_tup_read comes from index_getbitmap
SELECT pg_stat_reset();
SET enable_seqscan = off;
SET enable_bitmapscan = on;
SET enable_indexscan = on;
EXPLAIN (COSTS OFF) SELECT count(*) FROM (SELECT id FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox')) q;
SELECT count(*) FROM (SELECT id FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox')) q;
SELECT pg_stat_force_next_flush();
SELECT idx_scan, idx_tup_read FROM pg_stat_user_indexes WHERE indexrelname = 'ss_fts';

-- 2) Plain Index Scan (@@@ with bitmap disabled); idx_tup_read from index_getnext_tid
SELECT pg_stat_reset();
SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF) SELECT count(*) FROM (SELECT id FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox')) q;
SELECT count(*) FROM (SELECT id FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox')) q;
SELECT pg_stat_force_next_flush();
SELECT idx_scan, idx_tup_read FROM pg_stat_user_indexes WHERE indexrelname = 'ss_fts';
RESET enable_bitmapscan;

-- 3) count(*) pushdown (Custom Scan FtsCount)
SELECT pg_stat_reset();
EXPLAIN (COSTS OFF) SELECT count(*) FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox');
SELECT count(*) FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox');
SELECT pg_stat_force_next_flush();
SELECT idx_scan, idx_tup_read FROM pg_stat_user_indexes WHERE indexrelname = 'ss_fts';

-- 4) fts_search() native top-k (k=10 -> 10 index entries returned)
SELECT pg_stat_reset();
SELECT count(*) FROM fts_search('ss_fts', to_ftsquery('quick & fox'), 10);
SELECT pg_stat_force_next_flush();
SELECT idx_scan, idx_tup_read FROM pg_stat_user_indexes WHERE indexrelname = 'ss_fts';

-- 5) fts_count() native count
SELECT pg_stat_reset();
SELECT fts_count('ss_fts', to_ftsquery('quick & fox'));
SELECT pg_stat_force_next_flush();
SELECT idx_scan, idx_tup_read FROM pg_stat_user_indexes WHERE indexrelname = 'ss_fts';

-- Restore planner settings for the ranked cases below (default costing lets the
-- ordered index scan win; enabling seq scan also avoids the version-specific
-- "Disabled:" EXPLAIN annotation on PG18+ for the bare-ORDER-BY case).
RESET enable_seqscan;
RESET enable_bitmapscan;
RESET enable_indexscan;

-- 6) Ranked index-ordering scan: a WHERE @@@ restricts to the match set and
--    ORDER BY <=> is served in score order straight from the index (the
--    bm25_gettuple ranked path).  LIMIT 5 -> 5 index entries returned.
SELECT pg_stat_reset();
EXPLAIN (COSTS OFF)
  SELECT id FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox')
  ORDER BY to_ftsdoc(body) <=> to_ftsquery('quick & fox') LIMIT 5;
SELECT count(*) FROM (
  SELECT id FROM ss WHERE to_ftsdoc(body) @@@ to_ftsquery('quick & fox')
  ORDER BY to_ftsdoc(body) <=> to_ftsquery('quick & fox') LIMIT 5) q;
SELECT pg_stat_force_next_flush();
SELECT idx_scan, idx_tup_read FROM pg_stat_user_indexes WHERE indexrelname = 'ss_fts';

-- 7) A bare ORDER BY <=> with no @@@ filter cannot use the index: ranking the
--    whole corpus would also need the non-matching documents (all at maximum
--    distance), which the posting lists do not carry -- so it is a Sort over a
--    Seq Scan and idx_scan correctly stays 0.
SELECT pg_stat_reset();
EXPLAIN (COSTS OFF) SELECT id FROM ss ORDER BY to_ftsdoc(body) <=> to_ftsquery('quick fox') LIMIT 5;
SELECT count(*) FROM (SELECT id FROM ss ORDER BY to_ftsdoc(body) <=> to_ftsquery('quick fox') LIMIT 5) q;
SELECT pg_stat_force_next_flush();
SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelname = 'ss_fts';

DROP TABLE ss;
