-- vacuum_parallel (1.14.0): a manual VACUUM of a table with an fts index plus
-- two or more other large indexes uses parallel index vacuuming.  The fts index's
-- cleanup truncates its free tail, which takes AccessExclusiveLock; under
-- wal_level >= replica (PostgreSQL 18) that logs the lock for hot standby and so
-- assigns a transaction id -- an ERROR in parallel mode ("cannot assign
-- transaction IDs during a parallel operation").  The whole VACUUM rolled back,
-- so relfrozenxid never advanced.  Introduced in 1.11.0 (ada32aa).
--
-- bm25_truncate_lock now declines truncation in parallel mode (the tail stays in
-- the FSM, a later non-parallel VACUUM / fts_vacuum reclaims it), so the VACUUM
-- completes.  The trigger needs a real free tail at the end of the fts file, so
-- this builds one: insert, delete the high docid range, merge (which frees the
-- trailing pages), then VACUUM in parallel.  On PostgreSQL 17 the xid is not
-- assigned for this lock so the bug does not fire, but the test still passes
-- (the VACUUM completes and the counts match) -- it is a live guard only on 18.
--
-- 1.14.1: declining the truncation was not enough.  The cleanup's compaction
-- then ran its extend-only "vacate" rewrite, whose growth only a truncation
-- gives back, so every parallel VACUUM grew the fts file by about its live size
-- and only a non-parallel VACUUM shrank it.  The vacate now runs only under
-- AccessExclusiveLock (fts_vacuum); the size checks below fail on 1.14.0 on
-- both PostgreSQL 17 and 18.
SET client_min_messages = warning;
-- autovacuum off: an autovacuum of vp (120k dead rows below) would compact the
-- index before the size checks and make them vacuous
CREATE TABLE vp (id int PRIMARY KEY, body text, a int, b text)
  WITH (autovacuum_enabled = off);
INSERT INTO vp
  SELECT g,
         (SELECT string_agg('w' || ((g + i * 13) % 6000), ' ')
            FROM generate_series(1, 80) i),
         g % 1000, md5(g::text)
    FROM generate_series(1, 150000) g;
CREATE INDEX vp_fts ON vp USING fts (to_ftsdoc('english', body));
CREATE INDEX vp_b ON vp (b);
CREATE INDEX vp_ab ON vp (a, b);

-- free the tail of the fts file: delete the high docid range and merge, so the
-- merged segment is rewritten and the trailing pages become a free tail that
-- cleanup will try to truncate
DELETE FROM vp WHERE id > 30000;
SELECT fts_merge('vp_fts') IS NOT NULL AS merged;
CREATE TEMP TABLE vp_size AS SELECT pg_relation_size('vp_fts') AS s0;
DELETE FROM vp WHERE id % 100 = 7;   -- a few dead TIDs so bulkdelete also runs

-- force parallel index vacuuming (three indexes past min_parallel_index_scan_size,
-- workers allowed).  Under the bug this ERRORs on PG 18; the fix lets it finish.
SET min_parallel_index_scan_size = 0;
SET max_parallel_maintenance_workers = 2;
VACUUM (PARALLEL 2) vp;

-- the index still answers correctly after the parallel vacuum: index-driven count
-- of a surviving token equals a sequential-scan count of the same token (MVCC
-- correctness held; no live row lost, no dead row resurrected).  Word boundary so
-- 'w1' does not also catch 'w10', 'w100', ...
SET enable_seqscan = off;
SELECT count(*) > 0 AS has_matches FROM vp WHERE to_ftsdoc('english', body) @@@ 'w1'::ftsquery;
SELECT (SELECT count(*) FROM vp WHERE to_ftsdoc('english', body) @@@ 'w1'::ftsquery)
     = (SELECT count(*) FROM vp WHERE body ~ '\mw1\M') AS index_matches_heap;

-- two more parallel VACUUMs still succeed, and none of the three grew the fts
-- file (1.14.0: about +10% of the file each).  The slack covers the small
-- tombstone blobs each bulkdelete writes.
DELETE FROM vp WHERE id % 100 = 8;
VACUUM (PARALLEL 2) vp;
DELETE FROM vp WHERE id % 100 = 9;
VACUUM (PARALLEL 2) vp;
SELECT pg_relation_size('vp_fts') <= s0 + 64 * 8192 AS parallel_no_growth FROM vp_size;
SELECT 'vacuum_parallel ok' AS result;

-- non-parallel VACUUMs still compact and truncate the space the merge freed
-- (the first truncates the tail the parallel passes' pack left, the second
-- packs and truncates the rest)
DELETE FROM vp WHERE id % 100 = 10;
VACUUM (PARALLEL 0) vp;
DELETE FROM vp WHERE id % 100 = 11;
VACUUM (PARALLEL 0) vp;
SELECT pg_relation_size('vp_fts') < s0 / 2 AS serial_reclaims FROM vp_size;
SELECT (SELECT count(*) FROM vp WHERE to_ftsdoc('english', body) @@@ 'w1'::ftsquery)
     = (SELECT count(*) FROM vp WHERE body ~ '\mw1\M') AS index_matches_heap_after;

RESET enable_seqscan;
RESET min_parallel_index_scan_size;
RESET max_parallel_maintenance_workers;
DROP TABLE vp;
