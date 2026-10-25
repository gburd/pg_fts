-- E1: dead tuples (aborted inserts) whose index entries sit in the pending list,
-- then VACUUM, then slot reuse by non-matching rows.
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
DROP TABLE IF EXISTS e1;
CREATE EXTENSION IF NOT EXISTS pg_fts;
SELECT extversion FROM pg_extension WHERE extname='pg_fts';
CREATE TABLE e1 (id bigint, message text) WITH (autovacuum_enabled = off);
INSERT INTO e1 SELECT g, 'base row ' || g FROM generate_series(1, 2000) g;
CREATE INDEX e1_fts ON e1 USING fts (to_ftsdoc('english', message));
-- aborted inserts that contain the term
BEGIN;
INSERT INTO e1 SELECT g, 'visibility map change ' || g FROM generate_series(10001, 10300) g;
ROLLBACK;
VACUUM e1;
-- reuse the freed slots with rows that do NOT contain the term
INSERT INTO e1 SELECT g, 'other text ' || g FROM generate_series(20001, 20300) g;
SET enable_seqscan = off; SET enable_indexscan = off;
SELECT count(*) AS idx_rows,
       count(*) FILTER (WHERE NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))) AS idx_false
FROM (SELECT message FROM e1 WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','visibility & map') OFFSET 0) s;
RESET enable_seqscan; RESET enable_indexscan;
SELECT count(*) AS truth FROM e1 WHERE fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'));
