-- pending_reuse: an importer's batch is rolled back (or fails part-way), VACUUM
-- frees its heap slots, and the batch is retried without its first row, so each
-- retried row lands one slot below its aborted copy.  The aborted rows' index
-- entries were still in the pending list.  Before 1.11.0 VACUUM never offered
-- pending entries to its dead-row callback, so each kept its posting and the row
-- that reused the slot inherited the aborted document's terms: an index scan
-- returned a true match and, one slot higher, a row whose own @@@ is false, as
-- an exact match (no recheck).  Such an index stays wrong after an in-place
-- upgrade; REINDEX clears it (CHANGELOG 1.14.2, which documents the check run
-- below -- this test proves the check reports the false rows when they exist).
SET client_min_messages = warning;
CREATE TABLE pr (id int, message text) WITH (autovacuum_enabled = off);
INSERT INTO pr SELECT g, 'base row ' || g FROM generate_series(1, 5000) g;
CREATE INDEX pr_fts ON pr USING fts (to_ftsdoc('english', message));
CREATE TEMP TABLE batch AS
  SELECT 10000 + g AS id,
         CASE WHEN g % 2 = 0 THEN 'Move visibility map memory ordering comments ' || g
              ELSE 'Clean up usage of hash_any() ' || g END AS message
  FROM generate_series(1, 400) g;
BEGIN;
INSERT INTO pr SELECT id, message FROM batch ORDER BY id;
-- psql variables survive the rollback: where the aborted rows were
SELECT min(ctid) AS amin, max(ctid) AS amax FROM pr WHERE id > 10000 \gset
ROLLBACK;
VACUUM pr;
INSERT INTO pr SELECT id, message FROM batch WHERE id > 10001 ORDER BY id;
-- the retried rows took the aborted rows' slots, else this proves nothing
SELECT count(*) AS retried_rows_in_aborted_slots
FROM pr WHERE id > 10000 AND ctid >= :'amin' AND ctid <= :'amax';
-- the check documented in CHANGELOG 1.14.2: rows the index returns although
-- their own document does not match (bitmap scan, then plain index scan)
SET enable_seqscan = off;
SET enable_indexscan = off;
EXPLAIN (COSTS OFF)
SELECT ctid FROM pr
 WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', 'visibility & map')
   AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', 'visibility & map'));
SELECT count(*) AS bitmap_false_rows FROM (
  SELECT ctid FROM pr
   WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', 'visibility & map')
     AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', 'visibility & map'))
  OFFSET 0) s;
RESET enable_indexscan;
SET enable_bitmapscan = off;
SELECT count(*) AS indexscan_false_rows FROM (
  SELECT ctid FROM pr
   WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', 'visibility & map')
     AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', 'visibility & map'))
  OFFSET 0) s;
RESET enable_bitmapscan;
-- and the counts: through the index, from the heap rows, and fts_count
SELECT (SELECT count(*) FROM (SELECT 1 FROM pr WHERE to_ftsdoc('english', message)
          @@@ to_ftsquery('english', 'visibility & map') OFFSET 0) s) AS index_rows,
       (SELECT count(*) FROM pr WHERE fts_match(to_ftsdoc('english', message),
          to_ftsquery('english', 'visibility & map'))) AS heap_rows,
       fts_count('pr_fts', to_ftsquery('english', 'visibility & map')) AS fts_count;
RESET enable_seqscan;
-- the same after the cleanup flush and a merge
VACUUM pr;
SELECT fts_merge('pr_fts') IS NOT NULL AS merged;
SET enable_seqscan = off;
SELECT count(*) AS false_rows_after_merge FROM (
  SELECT ctid FROM pr
   WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', 'visibility & map')
     AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', 'visibility & map'))
  OFFSET 0) s;
RESET enable_seqscan;
DROP TABLE pr;
