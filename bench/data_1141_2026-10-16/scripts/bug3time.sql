SET client_min_messages = warning;
\o /dev/null
EXPLAIN ANALYZE SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery;
\o
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery LIMIT 20;
