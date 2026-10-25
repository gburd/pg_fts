-- shift: abort a batch, VACUUM frees its slots, retry the batch minus its first row
-- (the importer dropped the row that failed) so every retried row lands one slot lower.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
DROP TABLE IF EXISTS sh;
CREATE TABLE sh (id int, message text) WITH (autovacuum_enabled = off);
INSERT INTO sh SELECT g, 'base row ' || g FROM generate_series(1, 5000) g;
CREATE INDEX sh_fts ON sh USING fts (to_ftsdoc('english', message));
CREATE TEMP TABLE batch AS
  SELECT g AS id, CASE WHEN g % 2 = 0 THEN 'Move visibility map memory ordering comments ' || g
                       ELSE 'Clean up usage of hash_any() ' || g END AS message
  FROM generate_series(1, 400) g;
BEGIN; INSERT INTO sh SELECT id, message FROM batch ORDER BY id; ROLLBACK;
VACUUM sh;
INSERT INTO sh SELECT id, message FROM batch WHERE id > 1 ORDER BY id;
SET enable_seqscan = off; SET enable_indexscan = off;
CREATE TEMP TABLE got AS SELECT ctid AS tid, message FROM sh WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', 'visibility & map');
RESET enable_seqscan; RESET enable_indexscan;
SELECT (SELECT count(*) FROM sh WHERE fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))) AS truth,
       (SELECT count(*) FROM got) AS bitmap_rows,
       (SELECT count(*) FROM got WHERE NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))) AS bitmap_false,
       fts_count('sh_fts', to_ftsquery('english','visibility & map')) AS fts_count;
SELECT tid, left(message, 40) AS message, fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map')) AS rowpred
FROM got ORDER BY tid LIMIT 4;
