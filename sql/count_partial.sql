-- count_partial (1.15.0, ROADMAP I17a): count(*) is answered from a PARTIAL fts
-- index when the query's other quals are equivalent to the index predicate.
-- Through 1.14.3 the pushdown skipped every partial index (1.14.1 made it, rightly,
-- stop counting from one whose predicate the quals do not match).  A partial index
-- holds exactly the rows its predicate P admits, so its count answers
-- `R AND d @@@ q` iff R <=> P: R => P (the planner's predOK) and P => R (proved
-- with the same predicate prover).  Anything not provable falls back.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE cp (id int, live bool NOT NULL, d ftsdoc) WITH (autovacuum_enabled = off);
INSERT INTO cp SELECT g, g % 3 <> 0, to_ftsdoc('simple', 'alpha w' || (g % 10) || CASE WHEN g % 7 = 0 THEN ' beta' END)
  FROM generate_series(1, 3000) g;
CREATE INDEX cp_live ON cp USING fts (d) WHERE live;
CREATE INDEX cp_low ON cp USING fts (d) WHERE id <= 1000;
VACUUM ANALYZE cp;

CREATE FUNCTION pg_temp.pushed(sql text) RETURNS bool LANGUAGE plpgsql AS $$
DECLARE l text; found bool := false;
BEGIN
  FOR l IN EXECUTE 'EXPLAIN (COSTS OFF) ' || sql LOOP
    IF l ~ 'FtsCount' THEN found := true; END IF;
  END LOOP;
  RETURN found;
END $$;
CREATE FUNCTION pg_temp.heapcount(sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off;
  SET LOCAL enable_seqscan = on;
  EXECUTE sql INTO n;
  RETURN n;
END $$;
CREATE TABLE cq (q text, expect_pushed bool);
INSERT INTO cq VALUES
  -- equivalent to a predicate: pushed down
  ($$SELECT count(*) FROM cp WHERE live AND d @@@ 'beta'::ftsquery$$, true),
  ($$SELECT count(*) FROM cp WHERE d @@@ 'alpha & w3'::ftsquery AND live$$, true),
  ($$SELECT count(*) FROM cp WHERE id <= 1000 AND d @@@ 'beta'::ftsquery$$, true),
  -- implies a predicate but narrower: not equivalent, not pushed
  ($$SELECT count(*) FROM cp WHERE id <= 500 AND d @@@ 'beta'::ftsquery$$, false),
  ($$SELECT count(*) FROM cp WHERE live AND id > 5 AND d @@@ 'beta'::ftsquery$$, false),
  -- implies no predicate: not pushed (and no full index)
  ($$SELECT count(*) FROM cp WHERE NOT live AND d @@@ 'beta'::ftsquery$$, false),
  ($$SELECT count(*) FROM cp WHERE d @@@ 'beta'::ftsquery$$, false),
  -- volatile qual: never pushed
  ($$SELECT count(*) FROM cp WHERE live AND random() >= 0 AND d @@@ 'beta'::ftsquery$$, false);
-- pushed exactly where expected, and every count is non-zero (not 0 = 0)
SELECT q, expect_pushed, pg_temp.pushed(q) AS pushed, pg_temp.heapcount(q) > 0 AS nonzero
  FROM cq ORDER BY q;
CREATE FUNCTION pg_temp.planned_count(sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  EXECUTE sql INTO n;
  RETURN n;
END $$;
-- every count equals the seq-scan count
SELECT q, pg_temp.planned_count(q) = pg_temp.heapcount(q) AS count_matches_heap
  FROM cq ORDER BY q;
-- deletes are honoured: tombstones + visibility, the same as the non-partial pushdown
DELETE FROM cp WHERE id % 14 = 0;
SELECT pg_temp.pushed($$SELECT count(*) FROM cp WHERE live AND d @@@ 'beta'::ftsquery$$) AS pushed_after_delete,
       pg_temp.planned_count($$SELECT count(*) FROM cp WHERE live AND d @@@ 'beta'::ftsquery$$)
     = pg_temp.heapcount($$SELECT count(*) FROM cp WHERE live AND d @@@ 'beta'::ftsquery$$) AS count_matches_heap_after_delete;
DROP TABLE cp, cq;
