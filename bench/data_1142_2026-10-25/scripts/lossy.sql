-- S3(a): does the documented check (bitmap path, default work_mem) under-report on a very common term
-- because the bitmap goes lossy and the Recheck drops false rows on lossy pages?  Compare with a plain index scan.
\timing on
SHOW work_mem;
SET enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','fix')
   AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','fix')) OFFSET 0) s;
-- bitmap, default work_mem
SELECT 'bitmap default work_mem' AS arm, count(*) AS false_rows FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','fix')
   AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','fix')) OFFSET 0) s;
-- bitmap, large work_mem (exact pages)
SET work_mem = '1GB';
SELECT 'bitmap work_mem=1GB' AS arm, count(*) AS false_rows FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','fix')
   AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','fix')) OFFSET 0) s;
RESET work_mem;
-- plain index scan
SET enable_bitmapscan = off;
SELECT 'plain index scan' AS arm, count(*) AS false_rows FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','fix')
   AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','fix')) OFFSET 0) s;
RESET enable_bitmapscan; RESET enable_seqscan;
