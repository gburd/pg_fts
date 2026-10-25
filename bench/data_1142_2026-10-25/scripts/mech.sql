-- mech.sql: each way a heap slot can die while its fts entry is pending, then VACUUM + reuse by a non-matching row.
-- :mode = abort | conflict | delete | uniqfail | copyfail
\set ON_ERROR_STOP 0
SET client_min_messages = error;
DROP TABLE IF EXISTS mx;
CREATE TABLE mx (id int PRIMARY KEY, message text) WITH (autovacuum_enabled = off);
INSERT INTO mx SELECT g, CASE WHEN g % 100 = 0 THEN 'visibility map base ' ELSE 'base row ' END || g FROM generate_series(1, 5000) g;
CREATE INDEX mx_fts ON mx USING fts (to_ftsdoc('english', message));
VACUUM mx;
SELECT :'mode' = 'abort' AS m_abort, :'mode' = 'conflict' AS m_conflict, :'mode' = 'delete' AS m_delete,
       :'mode' = 'uniqfail' AS m_uniqfail, :'mode' = 'copyfail' AS m_copyfail \gset
\if :m_abort
BEGIN; INSERT INTO mx SELECT 100000 + g, 'Move visibility map memory ordering comments ' || g FROM generate_series(1, 300) g; ROLLBACK;
\elif :m_conflict
-- re-import with ON CONFLICT DO NOTHING: rows whose id exists are super-deleted after their index entries are made
UPDATE mx SET message = message WHERE false;
INSERT INTO mx SELECT g, 'Move visibility map memory ordering comments ' || g FROM generate_series(1, 300) g ON CONFLICT (id) DO NOTHING;
\elif :m_delete
INSERT INTO mx SELECT 100000 + g, 'Move visibility map memory ordering comments ' || g FROM generate_series(1, 300) g;
DELETE FROM mx WHERE id > 100000;
\elif :m_uniqfail
-- batch fails on its last row (duplicate key) after 299 rows got heap + fts entries
INSERT INTO mx SELECT CASE WHEN g = 300 THEN 1 ELSE 100000 + g END, 'Move visibility map memory ordering comments ' || g FROM generate_series(1, 300) g;
\elif :m_copyfail
COPY mx FROM PROGRAM 'seq 1 3000 | awk ''{ if ($1==3000) print "bad\tx"; else print 100000+$1 "\tMove visibility map memory ordering comments " $1 }''';
\endif
\set ON_ERROR_STOP 1
-- committed sentinel after the dead slots, so VACUUM does not truncate them away
INSERT INTO mx VALUES (999999, 'sentinel');
VACUUM mx;
INSERT INTO mx SELECT 200000 + g, 'other text ' || g FROM generate_series(1, 300) g;
SET enable_seqscan = off; SET enable_indexscan = off;
CREATE TEMP TABLE bm AS SELECT ctid AS tid, message FROM mx WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','visibility & map');
SET enable_bitmapscan = off; SET enable_indexscan = on;
CREATE TEMP TABLE pi AS SELECT ctid AS tid, message FROM mx WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','visibility & map');
RESET enable_seqscan; RESET enable_bitmapscan;
SELECT format('%-9s truth %s | bitmap %s false %s | idxscan %s false %s | fts_count %s | reused_slots %s',
  :'mode',
  (SELECT count(*) FROM mx WHERE fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))),
  (SELECT count(*) FROM bm), (SELECT count(*) FROM bm WHERE NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))),
  (SELECT count(*) FROM pi), (SELECT count(*) FROM pi WHERE NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))),
  fts_count('mx_fts', to_ftsquery('english','visibility & map')),
  (SELECT count(*) FROM mx WHERE id > 200000 AND (ctid::text::point)[0] < (SELECT max((ctid::text::point)[0]) FROM mx WHERE id <= 5000) + 3));
