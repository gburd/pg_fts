-- limit_hint: the planner attaches LIMIT(+OFFSET) to the ORDER BY <=> Const so
-- the ordering scan's first WAND batch is exactly k (1.9.0).  The hint must
-- never change WHICH rows come back or their order, at any LIMIT/OFFSET, with
-- heavy score ties, through a cursor, or in a prepared statement.
SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;

-- 3000 docs; 'tie' appears exactly once in every doc and every doc has the same
-- length, so every 'tie' match has an IDENTICAL BM25 score: a worst case for a
-- batch boundary falling inside a run of equal scores.
CREATE TABLE lh (id int PRIMARY KEY, d ftsdoc);
INSERT INTO lh
SELECT g, to_ftsdoc('simple', 'tie w' || (g % 7) || ' x' || (g % 11) ||
                    CASE WHEN g % 5 = 0 THEN ' rare' ELSE ' pad' END)
FROM generate_series(1, 3000) g;
CREATE INDEX lh_fts ON lh USING fts (d);
VACUUM ANALYZE lh;

-- ground truth: the full ranked order, read once with no LIMIT (no hint).
CREATE TEMP TABLE truth AS
SELECT row_number() OVER () AS r, id
FROM (SELECT id FROM lh WHERE d @@@ to_ftsquery('simple','tie')
      ORDER BY d <=> to_ftsquery('simple','tie')) s;
SELECT count(*) AS truth_rows, count(DISTINCT id) AS truth_distinct FROM truth;

-- the plan really is Limit -> Index Scan (so the hint path is exercised)
EXPLAIN (COSTS OFF)
SELECT id FROM lh WHERE d @@@ to_ftsquery('simple','tie')
ORDER BY d <=> to_ftsquery('simple','tie') LIMIT 10;

-- every (limit, offset) window equals the same slice of an unhinted full scan
CREATE FUNCTION lh_check(lim int, off int, q text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE got int[]; want int[];
BEGIN
  EXECUTE format('SELECT array_agg(id) FROM (SELECT id FROM lh WHERE d @@@ to_ftsquery(''simple'',%L)
                  ORDER BY d <=> to_ftsquery(''simple'',%L) LIMIT %s OFFSET %s) s', q, q, lim, off)
    INTO got;
  EXECUTE format('SELECT array_agg(id ORDER BY r) FROM (SELECT row_number() OVER () r, id FROM
                  (SELECT id FROM lh WHERE d @@@ to_ftsquery(''simple'',%L)
                   ORDER BY d <=> to_ftsquery(''simple'',%L)) a) b WHERE r > %s AND r <= %s',
                 q, q, off, off + lim)
    INTO want;
  IF want IS NULL THEN RETURN got IS NULL; END IF;
  RETURN got = want;
END $$;
SELECT bool_and(lh_check(l, o, 'tie')) AS windows_match
FROM (VALUES (1),(7),(10),(64),(100),(101),(399),(400),(1000)) lims(l),
     (VALUES (0),(1),(9),(10),(99),(2500)) offs(o);
SELECT bool_and(lh_check(l, o, 'rare | w3')) AS windows_match_or
FROM (VALUES (1),(10),(50)) lims(l), (VALUES (0),(5),(200)) offs(o);
SELECT bool_and(lh_check(l, 0, 'tie & rare')) AS windows_match_and
FROM (VALUES (1),(10),(100),(600)) lims(l);

-- a cursor over a hinted plan (LIMIT 2000 => k=2000), fetched one row at a time
BEGIN;
DECLARE c CURSOR FOR
  SELECT id FROM lh WHERE d @@@ to_ftsquery('simple','tie')
  ORDER BY d <=> to_ftsquery('simple','tie') LIMIT 2000;
CREATE TEMP TABLE got_c (r serial, id int);
DO $$
DECLARE v int; cur refcursor := 'c';
BEGIN
  LOOP
    FETCH NEXT FROM cur INTO v;
    EXIT WHEN NOT FOUND;
    INSERT INTO got_c(id) VALUES (v);
  END LOOP;
END $$;
COMMIT;
SELECT count(*) AS cursor_rows, count(DISTINCT g.id) AS cursor_distinct,
       bool_and(g.id = t.id) AS cursor_same_order
FROM got_c g JOIN truth t USING (r);

-- unbounded ordering scan (no LIMIT => no hint) still returns everything
SELECT count(*) AS unbounded_rows FROM (SELECT id FROM lh WHERE d @@@ to_ftsquery('simple','tie')
  ORDER BY d <=> to_ftsquery('simple','tie')) s;

-- prepared statements: a parameter LIMIT (not a Const => no hint) and a
-- constant LIMIT, each executed past the generic-plan threshold
PREPARE p(int) AS SELECT array_agg(id) = (SELECT array_agg(id ORDER BY r) FROM truth WHERE r <= $1)
  FROM (SELECT id FROM lh WHERE d @@@ to_ftsquery('simple','tie')
        ORDER BY d <=> to_ftsquery('simple','tie') LIMIT $1) s;
PREPARE p10 AS SELECT array_agg(id) = (SELECT array_agg(id ORDER BY r) FROM truth WHERE r <= 10)
  FROM (SELECT id FROM lh WHERE d @@@ to_ftsquery('simple','tie')
        ORDER BY d <=> to_ftsquery('simple','tie') LIMIT 10) s;
EXECUTE p(10); EXECUTE p(10); EXECUTE p(10); EXECUTE p(10); EXECUTE p(10); EXECUTE p(10);
EXECUTE p(250);
EXECUTE p10; EXECUTE p10; EXECUTE p10; EXECUTE p10; EXECUTE p10; EXECUTE p10; EXECUTE p10;
DEALLOCATE p;
DEALLOCATE p10;

DROP FUNCTION lh_check(int, int, text);
DROP TABLE lh;
