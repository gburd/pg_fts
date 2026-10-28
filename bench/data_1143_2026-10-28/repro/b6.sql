SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE re2 (id int, d ftsdoc) WITH (autovacuum_enabled = off);
INSERT INTO re2 SELECT g, to_ftsdoc('simple', concat_ws(' ', 'w' || (g::bigint * 7919 % 500),
       'w' || (g::bigint * 104729 % 500),
       CASE WHEN g % 4 = 0 OR g = 12345 THEN 'apple' END, CASE WHEN g % 4 = 1 THEN 'banana' END,
       CASE WHEN g = 12345 THEN 'rare' END, CASE WHEN g % 1000 = 8 THEN 'hot dog' END))
  FROM generate_series(1, 20000) g;
CREATE INDEX re2_fts ON re2 USING fts (d);
VACUUM ANALYZE re2;
SET enable_seqscan = off; SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT id FROM re2 WHERE d @@@ 'apple | banana'::ftsquery ORDER BY d <=> 'apple | banana'::ftsquery LIMIT 10;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT id FROM re2 WHERE d @@@ 'zzzq & (apple | banana)'::ftsquery ORDER BY d <=> 'zzzq & (apple | banana)'::ftsquery LIMIT 10;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT id FROM re2 WHERE d @@@ 'zzzq & apple'::ftsquery ORDER BY d <=> 'zzzq & apple'::ftsquery LIMIT 10;
