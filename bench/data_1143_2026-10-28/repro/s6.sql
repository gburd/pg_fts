SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE g6 (id int, body text) WITH (autovacuum_enabled = off);
INSERT INTO g6 SELECT g, concat_ws(' ', 'w' || (g::bigint * 7919 % 500), 'w' || (g::bigint * 104729 % 500),
       CASE WHEN g % 4 = 0 OR g = 12345 THEN 'apple' END, CASE WHEN g % 4 = 1 THEN 'banana' END,
       CASE WHEN g = 12345 THEN 'rare' END) FROM generate_series(1, 40000) g;
CREATE INDEX g6_fts ON g6 USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE g6;
SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE FUNCTION bufs(qt text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE ln text; r text := '';
BEGIN
  FOR ln IN EXECUTE format('EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT id FROM g6 WHERE to_ftsdoc(''simple'', body) @@@ to_ftsquery(''simple'', %L) ORDER BY to_ftsdoc(''simple'', body) <=> to_ftsquery(''simple'', %L) LIMIT 10', qt, qt) LOOP
    IF ln ~ 'Buffers' OR ln ~ 'Index Scan' THEN r := r || ' | ' || trim(ln); END IF;
  END LOOP;
  RETURN r;
END $$;
SELECT q, bufs(q) FROM unnest(ARRAY['zzzq & apple', 'zzzq & (apple | banana)', 'rare & (apple | banana)', 'apple | banana', 'apple & !banana', '(apple | zzzq) & !banana']) q;
SELECT q, (SELECT array_agg(id) FROM (SELECT id FROM g6 WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', q) ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', q) LIMIT 5) s)
  FROM unnest(ARRAY['zzzq & (apple | banana)', 'rare & (apple | banana)', 'apple & !banana', '(apple | zzzq) & !banana', '!zzzq & rare']) q;
INSERT INTO g6 VALUES (99999, 'zzzq banana');
SELECT q, (SELECT array_agg(id) FROM (SELECT id FROM g6 WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', q) ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', q) LIMIT 5) s)
  FROM unnest(ARRAY['zzzq & (apple | banana)', 'zzzq & apple']) q;
