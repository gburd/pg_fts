SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
PREPARE ranked(text) AS
  SELECT id FROM docs
   WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', $1)
   ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', $1)
   LIMIT 10;
EXECUTE ranked('apple | banana');
\echo CORRECTNESS
SELECT q, (SELECT array_agg(id) FROM (SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', q)
           ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', q) LIMIT 10) s) AS ids
  FROM unnest(ARRAY['zzzq & apple', 'zzzq & (apple | banana)', 'rare & apple', 'rare & (apple | banana)', 'apple | banana', 'zzzq & (apple | ban:*)', 'zzzq & ban:*']) q;
\echo BUFFERS
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('zzzq & (apple | banana)');
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('rare & (apple | banana)');
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('zzzq & apple');
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE ranked('apple | banana');
\o /dev/null
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
\o
\echo TIMING zzzq & apple
\o /dev/null
\timing on
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
EXECUTE ranked('zzzq & apple');
\timing off
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
\o
\echo TIMING zzzq & (apple | banana)
\o /dev/null
\timing on
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
EXECUTE ranked('zzzq & (apple | banana)');
\timing off
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
\o
\echo TIMING rare & apple
\o /dev/null
\timing on
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
EXECUTE ranked('rare & apple');
\timing off
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
\o
\echo TIMING rare & (apple | banana)
\o /dev/null
\timing on
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
EXECUTE ranked('rare & (apple | banana)');
\timing off
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
\o
\echo TIMING apple | banana
\o /dev/null
\timing on
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
EXECUTE ranked('apple | banana');
\timing off
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
\o
\echo TIMING zzzq & (apple | ban:*)
\o /dev/null
\timing on
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
EXECUTE ranked('zzzq & (apple | ban:*)');
\timing off
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
\o
\echo TIMING zzzq & ban:*
\o /dev/null
\timing on
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
EXECUTE ranked('zzzq & ban:*');
\timing off
\o
