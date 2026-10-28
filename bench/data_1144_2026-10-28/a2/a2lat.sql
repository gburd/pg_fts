SET client_min_messages = warning; SET enable_seqscan = off; SET enable_bitmapscan = off;
PREPARE r(text, int) AS SELECT id FROM docs WHERE d @@@ to_ftsquery('english', $1) ORDER BY d <=> to_ftsquery('english', $1) LIMIT $2;
\echo CORRECTNESS
SELECT q, (SELECT md5(string_agg(id::text, ',')) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english', q) ORDER BY d <=> to_ftsquery('english', q) LIMIT 10) s) AS ids
  FROM unnest(ARRAY['world & war','film | music | album | band','united & states','year','slovakia & hungary','world & (war | battle)']) q;
\echo BUFFERS
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE r('world & war', 10);
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE r('film | music | album | band', 10);
\o /dev/null
SELECT pg_prewarm('docs_fts');
EXECUTE r('world & war', 10); EXECUTE r('film | music | album | band', 10); EXECUTE r('united & states', 10); EXECUTE r('year', 10); EXECUTE r('slovakia & hungary', 10); EXECUTE r('world & (war | battle)', 10);
\o
\timing on
\echo TIMING world & war
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\o /dev/null
EXECUTE r('world & war', 10);
\o
\echo TIMING film | music | album | band
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\o /dev/null
EXECUTE r('film | music | album | band', 10);
\o
\echo TIMING united & states
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\o /dev/null
EXECUTE r('united & states', 10);
\o
\echo TIMING year
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\o /dev/null
EXECUTE r('year', 10);
\o
\echo TIMING slovakia & hungary
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\o /dev/null
EXECUTE r('slovakia & hungary', 10);
\o
\echo TIMING world & (war | battle)
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
\o /dev/null
EXECUTE r('world & (war | battle)', 10);
\o
