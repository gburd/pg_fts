SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
PREPARE ranked(text) AS SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', $1) ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', $1) LIMIT 10;
EXECUTE ranked('apple | banana');
\echo CORRECTNESS
SELECT q, (SELECT array_agg(id) FROM (SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', q) ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', q) LIMIT 10) s) AS ids FROM unnest(ARRAY['zzzq & apple','zzzq & (apple | banana)','rare & apple','rare & (apple | banana)','apple | banana','zzzq & (apple | ban:*)','zzzq & ban:*','w7 & (apple | banana)','rare & (apple | banana | w5)','w7 & (apple | banana) & !rare','apple & (banana | w5)','rare & (apple | ban:*)']) q;
\echo ORACLE
SET pg_fts.bestfirst = off;
SELECT q, (SELECT array_agg(id) FROM (SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', q) ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', q) LIMIT 10) s) AS ids FROM unnest(ARRAY['zzzq & apple','zzzq & (apple | banana)','rare & apple','rare & (apple | banana)','apple | banana','zzzq & (apple | ban:*)','zzzq & ban:*','w7 & (apple | banana)','rare & (apple | banana | w5)','w7 & (apple | banana) & !rare','apple & (banana | w5)','rare & (apple | ban:*)']) q;
RESET pg_fts.bestfirst;
\echo BUFFERS
\echo BUF zzzq & apple
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('zzzq & apple');
\echo BUF zzzq & (apple | banana)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('zzzq & (apple | banana)');
\echo BUF rare & apple
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('rare & apple');
\echo BUF rare & (apple | banana)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('rare & (apple | banana)');
\echo BUF apple | banana
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('apple | banana');
\echo BUF zzzq & (apple | ban:*)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('zzzq & (apple | ban:*)');
\echo BUF zzzq & ban:*
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('zzzq & ban:*');
\echo BUF w7 & (apple | banana)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('w7 & (apple | banana)');
\echo BUF rare & (apple | banana | w5)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('rare & (apple | banana | w5)');
\echo BUF w7 & (apple | banana) & !rare
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('w7 & (apple | banana) & !rare');
\echo BUF apple & (banana | w5)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('apple & (banana | w5)');
\echo BUF rare & (apple | ban:*)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('rare & (apple | ban:*)');
\o /dev/null
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('apple | banana');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('w7 & (apple | banana)');
EXECUTE ranked('rare & (apple | banana | w5)');
EXECUTE ranked('w7 & (apple | banana) & !rare');
EXECUTE ranked('apple & (banana | w5)');
EXECUTE ranked('rare & (apple | ban:*)');
\o
\timing on
\echo TIMING zzzq & apple
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\o /dev/null
EXECUTE ranked('zzzq & apple');
\o
\echo TIMING zzzq & (apple | banana)
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | banana)');
\o
\echo TIMING rare & apple
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\o /dev/null
EXECUTE ranked('rare & apple');
\o
\echo TIMING rare & (apple | banana)
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana)');
\o
\echo TIMING apple | banana
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\o /dev/null
EXECUTE ranked('apple | banana');
\o
\echo TIMING zzzq & (apple | ban:*)
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\echo TIMING zzzq & ban:*
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\o /dev/null
EXECUTE ranked('zzzq & ban:*');
\o
\echo TIMING w7 & (apple | banana)
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana)');
\o
\echo TIMING rare & (apple | banana | w5)
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | banana | w5)');
\o
\echo TIMING w7 & (apple | banana) & !rare
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\o /dev/null
EXECUTE ranked('w7 & (apple | banana) & !rare');
\o
\echo TIMING apple & (banana | w5)
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\o /dev/null
EXECUTE ranked('apple & (banana | w5)');
\o
\echo TIMING rare & (apple | ban:*)
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
\o /dev/null
EXECUTE ranked('rare & (apple | ban:*)');
\o
