-- planner_indexes (1.14.1): which fts index the @@@ estimator (fts_matchsel)
-- and the count(*) pushdown may read.  Both now take it from the planner's own
-- index list (rel->indexlist).  Before, they walked the table's raw index list:
--  * the count pushdown answered from a PARTIAL index, so count(*) counted only
--    the rows its predicate admits (since the pushdown was added);
--  * fts_matchsel matched an expression index only when the table was the
--    query's first range-table entry (later entries got tsmatchsel's default);
--  * fts_matchsel read a partitioned table's partitioned index, which has no
--    storage, when it estimated a join clause: the query failed (1.14.0).
-- Invalid and too-new indexes: specs/bm25_cic_planner.spec.
SET client_min_messages = warning;

-- a partial index holds 100 of the 2000 rows that match
CREATE TABLE pi (id int, d ftsdoc) WITH (autovacuum_enabled = off);
INSERT INTO pi SELECT g, to_ftsdoc('simple', 'alpha w' || (g % 10)) FROM generate_series(1, 2000) g;
CREATE INDEX pi_fts ON pi USING fts (d) WHERE id <= 100;
VACUUM ANALYZE pi;
SELECT fts_count('pi_fts', 'alpha'::ftsquery) AS in_partial_index;
-- count(*) counts the table, not the partial index (1.14.0: 100)
EXPLAIN (COSTS OFF) SELECT count(*) FROM pi WHERE d @@@ 'alpha'::ftsquery;
SELECT count(*) AS alpha FROM pi WHERE d @@@ 'alpha'::ftsquery;
-- a query whose other quals ARE the predicate is counted from the partial index
-- (1.14.4, count_partial; 1.14.3 planned a bitmap scan, 1.14.1-1.14.2 a scan
-- estimated at 1 row); the count is the same
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT count(*) FROM pi WHERE d @@@ 'alpha'::ftsquery AND id <= 100;
SELECT count(*) AS alpha_le_100 FROM pi WHERE d @@@ 'alpha'::ftsquery AND id <= 100;
RESET enable_seqscan;

-- an expression index, with the table first and second in the range table
CREATE TABLE px (id int, body text) WITH (autovacuum_enabled = off);
INSERT INTO px SELECT g, 'alpha doc' || CASE WHEN g = 17 THEN ' rare' ELSE '' END
  FROM generate_series(1, 20000) g;
CREATE INDEX px_fts ON px USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE px;
-- the planner's row estimate for the scan of px in a statement
CREATE FUNCTION px_rows(stmt text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE ln text;
BEGIN
  FOR ln IN EXECUTE 'EXPLAIN ' || stmt LOOP
    IF ln ~ ' on px' THEN RETURN (regexp_match(ln, 'rows=(\d+)'))[1]::int; END IF;
  END LOOP;
  RETURN NULL;
END $$;
SELECT px_rows($q$SELECT 1 FROM px WHERE to_ftsdoc('simple', px.body) @@@ 'rare'::ftsquery$q$)
         <= 5 AS first_rte_from_index,
       px_rows($q$SELECT 1 FROM (VALUES (1)) v(x), px
                  WHERE to_ftsdoc('simple', px.body) @@@ 'rare'::ftsquery$q$)
         <= 5 AS second_rte_from_index;

-- a join clause over a partitioned table (1.14.0: could not open file)
CREATE TABLE ppt (id int, d ftsdoc) PARTITION BY RANGE (id);
CREATE TABLE ppt1 PARTITION OF ppt FOR VALUES FROM (0) TO (1000);
CREATE TABLE ppt2 PARTITION OF ppt FOR VALUES FROM (1000) TO (3000);
INSERT INTO ppt SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 2500) g;
CREATE INDEX ppt_fts ON ppt USING fts (d);
CREATE TABLE po (x int);
INSERT INTO po VALUES (1), (2);
ANALYZE ppt;
ANALYZE po;
SELECT count(*) AS joined FROM ppt JOIN po ON (ppt.d @@@ 'alpha'::ftsquery OR po.x = ppt.id);

DROP FUNCTION px_rows(text);
DROP TABLE pi;
DROP TABLE px;
DROP TABLE ppt;
DROP TABLE po;
