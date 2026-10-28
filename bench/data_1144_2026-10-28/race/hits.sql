SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE FUNCTION pg_temp.hits(qt text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE l text; h int := 0;
BEGIN
  FOR l IN EXECUTE format('EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
      SELECT id FROM rd WHERE d @@@ %L::ftsquery ORDER BY d <=> %L::ftsquery LIMIT 10', qt, qt)
  LOOP
    IF l ~ '^\s*Buffers: shared hit=' AND h = 0 THEN h := substring(l from 'hit=(\d+)')::int; END IF;
  END LOOP;
  RETURN h;
END $$;
SELECT q, pg_temp.hits(q) FROM unnest(ARRAY['zzzq & (apple | ban:*)','zzzq & ban:*','zzzq & (apple | banana | cherry | ban:*)','zzzq & cherry & ban:*','apple & ban:*','ban:*']) q;
