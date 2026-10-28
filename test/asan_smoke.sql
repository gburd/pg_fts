-- test/asan_smoke.sql: a small, fast exercise of pg_fts's in-process C paths,
-- for the AddressSanitizer CI job (sanitizers).  The full regression suite is
-- impractical under ASan's ~15x slowdown -- a few tests load large synthetic
-- corpora and run delete/vacuum loops that take many minutes each.  This drives
-- every memory-critical path on small data: build, each query type, the pending
-- flush, bulkdelete + vacuum tail-truncation, segment merge, both doclen modes.
-- Every *_ok check goes through ok(), which raises unless the check is true
-- (false or NULL), so with ON_ERROR_STOP psql exits non-zero and the CI step
-- fails; ASan asserts no memory error on top.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE FUNCTION pg_temp.ok(check_name text, v bool) RETURNS bool LANGUAGE plpgsql AS $$
BEGIN
  IF v IS NOT TRUE THEN
    RAISE EXCEPTION 'asan_smoke: check % is %', check_name, coalesce(v::text, 'NULL');
  END IF;
  RETURN v;
END $$;

-- two indexes, sidecar on and off, so both bulkdelete docid paths run
CREATE TABLE a (id int PRIMARY KEY, body text);
INSERT INTO a SELECT g,
  'alpha w' || (g % 60) || ' beta' || (CASE WHEN g % 3 = 0 THEN ' gamma' ELSE '' END)
    || ' united states of ' || (CASE WHEN g % 7 = 0 THEN 'america' ELSE 'europe' END)
  FROM generate_series(1, 4000) g;
CREATE INDEX a_on  ON a USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=on, positions=on);
CREATE INDEX a_off ON a USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=off, positions=on);
VACUUM (FREEZE, ANALYZE) a;
SET enable_seqscan = off;

-- every query type, index-driven, with a correctness anchor from a seq scan
SELECT pg_temp.ok('term_ok', count(*) = (SELECT count(*) FROM a WHERE body ~ '\malpha\M')) AS term_ok
  FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery;
SELECT pg_temp.ok('and_ok', count(*) = (SELECT count(*) FROM a WHERE body ~ '\mbeta\M' AND body ~ '\mgamma\M')) AS and_ok
  FROM a WHERE to_ftsdoc('simple', body) @@@ 'beta & gamma'::ftsquery;
SELECT pg_temp.ok('or_ok', count(*) > 0) AS or_ok     FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha | zzz'::ftsquery;
SELECT pg_temp.ok('not_ok', count(*) > 0) AS not_ok    FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha & !gamma'::ftsquery;
SELECT pg_temp.ok('phrase_ok', count(*) > 0) AS phrase_ok FROM a WHERE to_ftsdoc('simple', body) @@@ '"united states"'::ftsquery;
SELECT pg_temp.ok('near_ok', count(*) > 0) AS near_ok   FROM a WHERE to_ftsdoc('simple', body) @@@ 'united w/3 america'::ftsquery;
SELECT pg_temp.ok('prefix_ok', count(*) > 0) AS prefix_ok FROM a WHERE to_ftsdoc('simple', body) @@@ 'alph:*'::ftsquery;
SELECT pg_temp.ok('fuzzy_ok', count(*) > 0) AS fuzzy_ok  FROM a WHERE to_ftsdoc('simple', body) @@@ 'alphx~1'::ftsquery;

-- ranked top-k (best-first + MaxScore paths)
SELECT pg_temp.ok('rank_ok', count(*) = 10) AS rank_ok
  FROM (SELECT id FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery
        ORDER BY to_ftsdoc('simple', body) <=> 'alpha'::ftsquery LIMIT 10) s;

-- fts_bm25 / fts_bm25_opts with a dfs array shorter than the query (1.14.3,
-- Codeberg #9): every query term is in the doc, so each one reads its dfs
-- slot; a term past the end of the array must score as df = 1 (a NULL dfs)
-- instead of reading up to 16 kB past the array's palloc'd copy.
SELECT pg_temp.ok('bm25_short_dfs_ok',
         fts_bm25(d, q, 1e12, 20, '{}'::float8[]) = fts_bm25(d, q, 1e12, 20)
     AND fts_bm25(d, q, 1e12, 20, ARRAY[1e9]::float8[])
       = fts_bm25(d, q, 1e12, 20, array_prepend(1e9::float8, array_fill(1::float8, ARRAY[1999])))
     AND fts_bm25_opts(d, q, 1e12, 20, 1.2, 0.75, 'bm25l', '{}'::float8[])
       = fts_bm25_opts(d, q, 1e12, 20, 1.2, 0.75, 'bm25l', NULL)) AS bm25_short_dfs_ok
  FROM (SELECT to_ftsdoc('simple', string_agg('t' || g, ' ')) AS d,
               to_ftsquery('simple', string_agg('t' || g, ' | ')) AS q
          FROM generate_series(1, 2000) g) s;

-- index-only exact count
SELECT pg_temp.ok('count_ok', fts_count('a_on', 'alpha'::ftsquery) = (SELECT count(*) FROM a WHERE body ~ '\malpha\M')) AS count_ok;

-- pending flush on insert (I12 path): insert past the threshold, then query
SET pg_fts.pending_flush_threshold = 500;
INSERT INTO a SELECT g, 'alpha delta' FROM generate_series(100001, 101200) g;
SELECT pg_temp.ok('pending_ok', count(*) > 0) AS pending_ok FROM a WHERE to_ftsdoc('simple', body) @@@ 'delta'::ftsquery;

-- the @@@ estimator (fts_matchsel) with documents pending: plan only
SET pg_fts.pending_flush_threshold = 0;
INSERT INTO a SELECT g, 'alpha epsilon' FROM generate_series(101201, 101400) g;
EXPLAIN (COSTS OFF) SELECT 1 FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha & !epsilon | delta'::ftsquery;
EXPLAIN (COSTS OFF) SELECT 1 FROM a WHERE to_ftsdoc('simple', body) @@@ 'alph*'::ftsquery;

-- bulkdelete + vacuum tail truncation + merge, both sidecar modes
DELETE FROM a WHERE id % 4 = 0;
VACUUM (INDEX_CLEANUP ON) a;
SELECT pg_temp.ok('merge_ok', fts_merge('a_on') IS NOT NULL AND fts_merge('a_off') IS NOT NULL) AS merge_ok;
SELECT pg_temp.ok('after_vacuum_ok', count(*) = (SELECT count(*) FROM a WHERE body ~ '\malpha\M')) AS after_vacuum_ok
  FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery;

RESET enable_seqscan;
RESET pg_fts.pending_flush_threshold;
DROP TABLE a;
\echo asan_smoke: all checks passed
