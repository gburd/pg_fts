-- vacuum_mem (1.14.0): bulkdelete must enumerate a segment's docids without
-- holding every posting resident at once.  Before 1.14.0 bm25_segment_docids
-- decoded every (term, doc) posting of the segment into one array and added it
-- to the sparsemap in a single call, so peak memory was ~24 bytes per posting
-- (hundreds of times the document count for a high-vocabulary field), ignored
-- maintenance_work_mem, and OOM'd a production server on a one-row delete.
--
-- A v4 segment (doclen_sidecar on) now reads its ascending docid list straight
-- from the sidecar at O(ndocs) with zero posting decodes; an inline-doclen
-- segment (sidecar off) walks the dictionary but flushes to the map in bounded
-- batches sized from maintenance_work_mem.  This asserts the OBSERVABLE
-- correctness of both paths across an INDEX_CLEANUP ON vacuum (the memory bound
-- itself is measured on a large corpus in bench/; a RAM assertion is not
-- deterministic in the shared regression cluster).  VACUUM cannot run inside a
-- function, so each mode is spelled out at top level.
SET client_min_messages = warning;

-- ---- sidecar ON: v4 fast path (O(ndocs), zero posting decode) ----
CREATE TABLE vm_on (id int PRIMARY KEY, body text);
INSERT INTO vm_on
  SELECT g, 'alpha ' || (SELECT string_agg('w' || ((g + i) % 4000), ' ')
                           FROM generate_series(1, 40) i)
    FROM generate_series(1, 3000) g;
CREATE INDEX vm_on_fts ON vm_on USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=on);
VACUUM (FREEZE) vm_on;
SELECT fts_index_nsegments('vm_on_fts') = 1 AS on_one_segment;

DELETE FROM vm_on WHERE id = 1;
SET maintenance_work_mem = '1MB';   -- tiny: the old code ignored this entirely
VACUUM (INDEX_CLEANUP ON) vm_on;
RESET maintenance_work_mem;

SET enable_seqscan = off;
SELECT (SELECT count(*) FROM vm_on WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery)
     = (SELECT count(*) FROM vm_on WHERE body ~ '\malpha\M') AS on_index_matches_heap,
       (SELECT count(*) FROM vm_on WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery) = 2999 AS on_count_2999;
SELECT NOT EXISTS (SELECT 1 FROM vm_on WHERE id = 1
                   AND to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery) AS on_deleted_absent;
RESET enable_seqscan;

DELETE FROM vm_on WHERE id % 10 = 0;
VACUUM vm_on;
SET enable_seqscan = off;
SELECT (SELECT count(*) FROM vm_on WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery)
     = (SELECT count(*) FROM vm_on WHERE body ~ '\malpha\M') AS on_count_after_bulk;
RESET enable_seqscan;
DROP TABLE vm_on;

-- ---- sidecar OFF: inline-doclen batched path ----
CREATE TABLE vm_off (id int PRIMARY KEY, body text);
INSERT INTO vm_off
  SELECT g, 'alpha ' || (SELECT string_agg('w' || ((g + i) % 4000), ' ')
                           FROM generate_series(1, 40) i)
    FROM generate_series(1, 3000) g;
CREATE INDEX vm_off_fts ON vm_off USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=off);
VACUUM (FREEZE) vm_off;
SELECT fts_index_nsegments('vm_off_fts') = 1 AS off_one_segment;

DELETE FROM vm_off WHERE id = 1;
SET maintenance_work_mem = '1MB';
VACUUM (INDEX_CLEANUP ON) vm_off;
RESET maintenance_work_mem;

SET enable_seqscan = off;
SELECT (SELECT count(*) FROM vm_off WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery)
     = (SELECT count(*) FROM vm_off WHERE body ~ '\malpha\M') AS off_index_matches_heap,
       (SELECT count(*) FROM vm_off WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery) = 2999 AS off_count_2999;
SELECT NOT EXISTS (SELECT 1 FROM vm_off WHERE id = 1
                   AND to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery) AS off_deleted_absent;
RESET enable_seqscan;

DELETE FROM vm_off WHERE id % 10 = 0;
VACUUM vm_off;
SET enable_seqscan = off;
SELECT (SELECT count(*) FROM vm_off WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery)
     = (SELECT count(*) FROM vm_off WHERE body ~ '\malpha\M') AS off_count_after_bulk;
RESET enable_seqscan;
DROP TABLE vm_off;
