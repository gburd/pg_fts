-- pending_flush (1.14.0, I12): pg_fts.pending_flush_threshold bounds the pending
-- list from the insert path, so a ranked scan does not slow in proportion to the
-- unflushed inserts.  With the threshold at 0 (the pre-1.14 behaviour) nothing
-- flushes on insert, so the pending list grows with every row and the ranked scan's
-- candidate count climbs; with it set, an insert past the threshold flushes.
--
-- The index exposes no pending count in SQL, so the test uses two observable
-- consequences: the segment count (a flush appends a segment) and the ranked
-- top-k, which must stay correct either way.
SET client_min_messages = warning;
CREATE TABLE pf (id bigint PRIMARY KEY, d ftsdoc);
INSERT INTO pf SELECT g, to_ftsdoc('simple', 'alpha w' || (g % 97) || ' doc' || g)
  FROM generate_series(1, 4000) g;
CREATE INDEX pf_idx ON pf USING fts (d);
VACUUM ANALYZE pf;
SELECT fts_index_nsegments('pf_idx') AS segs_after_build;   -- 1

-- threshold 0: inserts never flush, so the segment count does not move no matter
-- how many rows are inserted (they all sit in the pending list)
SET pg_fts.pending_flush_threshold = 0;
INSERT INTO pf SELECT g, to_ftsdoc('simple', 'alpha beta w' || (g % 50))
  FROM generate_series(100001, 112000) g;
SELECT fts_index_nsegments('pf_idx') AS segs_threshold_0;   -- still 1

-- threshold set: an insert that crosses it flushes the pending list into a segment.
-- 12,000 more rows past a 2,000 threshold flush several times; the segment count
-- rises above 1 (the tiered compactor keeps it bounded, so this is a small number,
-- not 12000).
SET pg_fts.pending_flush_threshold = 2000;
INSERT INTO pf SELECT g, to_ftsdoc('simple', 'alpha gamma w' || (g % 50))
  FROM generate_series(200001, 212000) g;
SELECT fts_index_nsegments('pf_idx') > 1 AS flushed_on_insert,       -- t
       fts_index_nsegments('pf_idx') < 50 AS bounded;                -- t

-- every row is still found, from segments and the pending list alike
SET enable_seqscan = off;
SELECT count(*) = 24000 AS all_beta_gamma_found
FROM pf WHERE d @@@ 'alpha & (beta | gamma)'::ftsquery;
SELECT count(*) AS alpha_rows FROM pf WHERE d @@@ 'alpha'::ftsquery;  -- 28000

-- ranked top-10 over a term held by pending and flushed rows alike returns 10,
-- scored identically whether a row is pending or flushed (the pending_rank
-- property), on an index that has just taken an insert-time flush
SELECT count(*) = 10 AS ranked_ten
FROM (SELECT id FROM pf WHERE d @@@ 'beta'::ftsquery
      ORDER BY d <=> 'beta'::ftsquery LIMIT 10) s;
-- after a full merge the same top-10 ids and distances come back
CREATE TEMP TABLE pf_before AS
  SELECT id, round((d <=> 'beta'::ftsquery)::numeric, 12) dist
  FROM pf WHERE d @@@ 'beta'::ftsquery ORDER BY d <=> 'beta'::ftsquery LIMIT 10;
SELECT fts_merge('pf_idx') AS merged;
CREATE TEMP TABLE pf_after AS
  SELECT id, round((d <=> 'beta'::ftsquery)::numeric, 12) dist
  FROM pf WHERE d @@@ 'beta'::ftsquery ORDER BY d <=> 'beta'::ftsquery LIMIT 10;
SELECT (SELECT array_agg(id ORDER BY id) FROM pf_before)
     = (SELECT array_agg(id ORDER BY id) FROM pf_after) AS same_ids,
       (SELECT array_agg(dist ORDER BY id) FROM pf_before)
     = (SELECT array_agg(dist ORDER BY id) FROM pf_after) AS same_dists;
RESET enable_seqscan; RESET pg_fts.pending_flush_threshold;
DROP TABLE pf;
