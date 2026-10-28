-- I8 probe: CacheMemoryContext total after N failed rebuilds, N = 0,10,20,40,80; and with the hook OFF (control:
-- normal rebuilds after each merge) to separate the leak from ordinary relcache growth (new segments, new index pages)
LOAD 'pg_fts';
SET client_min_messages = warning;
DROP TABLE IF EXISTS cr;
CREATE TABLE cr (id int, body text) WITH (autovacuum_enabled = off);
INSERT INTO cr SELECT g, 'w' || (g % 4000) || ' x' || (g % 37) || ' common' FROM generate_series(1, 60000) g;
CREATE INDEX cr_fts ON cr USING fts (to_ftsdoc('simple', body));
SET pg_fts.pending_flush_threshold = 0;
SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE FUNCTION pg_temp.ranked() RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM (SELECT id FROM cr WHERE to_ftsdoc('simple', body) @@@ 'common'::ftsquery
    ORDER BY to_ftsdoc('simple', body) <=> 'common'::ftsquery LIMIT 10) s $$;
CREATE FUNCTION pg_temp.cache_bytes() RETURNS bigint LANGUAGE sql AS $$
  SELECT total_bytes FROM pg_backend_memory_contexts WHERE name = 'CacheMemoryContext' $$;
CREATE FUNCTION pg_temp.rounds(n int, fail bool) RETURNS int LANGUAGE plpgsql AS $$
DECLARE e int := 0;
BEGIN
  FOR i IN 1..n LOOP
    INSERT INTO cr VALUES (100000 + i, 'common fresh' || i);
    PERFORM fts_merge('cr_fts');
    BEGIN
      PERFORM set_config('pg_fts.test_cache_build_error', fail::text, true);
      PERFORM pg_temp.ranked();
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%test hook%' THEN e := e + 1; END IF;
    END;
    PERFORM set_config('pg_fts.test_cache_build_error', 'off', false);
  END LOOP;
  RETURN e;
END $$;
SELECT pg_temp.ranked();
SELECT 'start' AS phase, 0 AS errors, pg_temp.cache_bytes() AS bytes, fts_index_nsegments('cr_fts') AS nseg;
SELECT 'ok x40' AS phase, pg_temp.rounds(40, false) AS errors, pg_temp.cache_bytes() AS bytes, fts_index_nsegments('cr_fts') AS nseg;
SELECT 'fail x40' AS phase, pg_temp.rounds(40, true) AS errors, pg_temp.cache_bytes() AS bytes, fts_index_nsegments('cr_fts') AS nseg;
SELECT 'fail x80' AS phase, pg_temp.rounds(80, true) AS errors, pg_temp.cache_bytes() AS bytes, fts_index_nsegments('cr_fts') AS nseg;
SELECT 'ok x40' AS phase, pg_temp.rounds(40, false) AS errors, pg_temp.cache_bytes() AS bytes, fts_index_nsegments('cr_fts') AS nseg;
SELECT name, total_bytes FROM pg_backend_memory_contexts WHERE parent = 'CacheMemoryContext' OR name = 'CacheMemoryContext' ORDER BY total_bytes DESC LIMIT 6;
