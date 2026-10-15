-- planner_cost (1.14.0, I11): the @@@ restriction estimator, fts_matchsel.
-- It reads the term's document frequency from the bm25 index, so the planner's
-- row estimate reflects a common term vs a rare one, instead of tsmatchsel's
-- fixed default.  A wrong (small) estimate made the planner pick a bitmap scan +
-- Sort for ORDER BY d <=> q LIMIT k on an expression index, which then
-- re-evaluated the index expression per matching row (seconds instead of ms).
--
-- The test asserts the estimate and the chosen plan node, not any cost number,
-- so it is stable across hardware.
SET client_min_messages = warning;
SET enable_seqscan = off;
CREATE TABLE pc (id bigint PRIMARY KEY, body text);
-- 2000 rows: 'common' in every row, 'rare' in 5.  Distinct df so a per-term
-- estimate differs sharply from a fixed default.
INSERT INTO pc SELECT g,
  'common w' || (g % 40) || (CASE WHEN g <= 5 THEN ' rare' ELSE '' END)
  FROM generate_series(1, 2000) g;
CREATE INDEX pc_idx ON pc USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE pc;

-- helper: the planner's estimated row count for `body @@@ term`
CREATE FUNCTION pc_estrows(term text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE ln text; n int;
BEGIN
  FOR ln IN EXECUTE
    format('EXPLAIN SELECT 1 FROM pc WHERE to_ftsdoc(''simple'', body) @@@ %L::ftsquery', term)
  LOOP
    n := (regexp_match(ln, 'rows=(\d+)'))[1]::int;
    IF n IS NOT NULL THEN RETURN n; END IF;
  END LOOP;
  RETURN NULL;
END $$;

-- the operator now uses fts_matchsel
SELECT oprrest::regproc::text AS restrict_fn
FROM pg_operator WHERE oprname = '@@@'
  AND oprleft = 'ftsdoc'::regtype AND oprright = 'ftsquery'::regtype;

-- true df per term
SELECT (SELECT count(*) FROM pc WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery) AS rare_df,
       (SELECT count(*) FROM pc WHERE to_ftsdoc('simple', body) @@@ 'common'::ftsquery) AS common_df;

-- the estimate tracks the df: common's estimate dominates rare's (it did not
-- under tsmatchsel, which returned the same default for both)
SELECT pc_estrows('rare') <= 50 AS rare_small,
       pc_estrows('common') >= 1500 AS common_large,
       pc_estrows('common') >= 50 * greatest(pc_estrows('rare'), 1) AS common_dominates;

-- ranked LIMIT on a COMMON term stays on the ordering index scan (no Bitmap Heap
-- Scan, no Sort), because the estimator no longer under-counts it
EXPLAIN (COSTS OFF)
SELECT id FROM pc WHERE to_ftsdoc('simple', body) @@@ 'common'::ftsquery
ORDER BY to_ftsdoc('simple', body) <=> 'common'::ftsquery LIMIT 100;

EXPLAIN (COSTS OFF)
SELECT id FROM pc WHERE to_ftsdoc('simple', body) @@@ 'common'::ftsquery
ORDER BY to_ftsdoc('simple', body) <=> 'common'::ftsquery LIMIT 1000;

DROP FUNCTION pc_estrows(text);
RESET enable_seqscan;
DROP TABLE pc;
