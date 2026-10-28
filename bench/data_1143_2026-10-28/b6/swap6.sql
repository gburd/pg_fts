SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
PREPARE ranked(text) AS
  SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', $1)
   ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', $1) LIMIT 10;
EXECUTE ranked('apple | banana');
\o /dev/null
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
\o
