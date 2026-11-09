-- psql -v nrows=1880000 -v nmoves=23313 -f repro.sql   (scratch database only)
\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS own;
CREATE TABLE own (num bigint PRIMARY KEY, head text, own text) WITH (autovacuum_enabled = off);
SELECT setseed(0.42);
INSERT INTO own
SELECT g, 'subject ' || g,
       (SELECT string_agg('w' || floor(power(random(), 3) * 40000)::int, ' ')
          FROM generate_series(1, 40 + (g % 7) * 20) s WHERE g > 0)
       || CASE WHEN random() < 0.06 THEN ' remove' ELSE '' END
       || CASE WHEN random() < 0.03 THEN ' vacuum' ELSE '' END
  FROM generate_series(1, :nrows) g;
CREATE INDEX idx_own_fts ON own USING fts (to_ftsdoc('english'::regconfig, ((head || ' '::text) || own))) WITH (doclen_sidecar = off);
VACUUM ANALYZE own;
SELECT fts_vacuum('idx_own_fts'::regclass) \gset
CREATE OR REPLACE FUNCTION probe(label text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; a numeric; b numeric; c numeric;
BEGIN
  PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'remov'::ftsquery, 200);
  t0 := clock_timestamp(); PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'remov'::ftsquery, 200);
  a := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
  t0 := clock_timestamp(); PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'vacuum'::ftsquery, 200);
  b := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
  SET LOCAL pg_fts.bestfirst = off;
  t0 := clock_timestamp(); PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'remov'::ftsquery, 200);
  c := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
  RETURN format('%-50s segs %s  remove %s ms  vacuum %s ms  remove/bestfirst=off %s ms',
                label, fts_index_nsegments('idx_own_fts'::regclass), a, b, c);
END $$;
-- delete n scattered rows and re-insert their text under new keys, in 24 transactions
CREATE OR REPLACE PROCEDURE moves(n int) LANGUAGE plpgsql AS $$
DECLARE b int; base bigint;
BEGIN
  SELECT max(num) INTO base FROM own;
  CREATE TEMP TABLE IF NOT EXISTS mv (num bigint);
  TRUNCATE mv;
  INSERT INTO mv SELECT num FROM own ORDER BY random() LIMIT n;
  FOR b IN 0..23 LOOP
    WITH d AS (DELETE FROM own o USING (SELECT num FROM mv WHERE num % 24 = b) m
               WHERE o.num = m.num RETURNING o.num, o.head, o.own)
    INSERT INTO own SELECT base + num, head, own FROM d;
    COMMIT;
  END LOOP;
END $$;
SELECT probe('A fresh build, packed');
CALL moves(:nmoves);
SELECT probe('B moves');
SELECT fts_vacuum('idx_own_fts'::regclass) \gset
SELECT probe('C then fts_vacuum');
VACUUM own;
SELECT probe('D then VACUUM');
SELECT fts_vacuum('idx_own_fts'::regclass) AS did \gset
SELECT probe('E then fts_vacuum (returned ' || :'did' || ')');
SELECT fts_merge('idx_own_fts'::regclass) AS did \gset
SELECT probe('F then fts_merge (returned ' || :'did' || ')');
REINDEX INDEX idx_own_fts;
SELECT probe('G REINDEX');
CALL moves(:nmoves);
VACUUM own;
SELECT fts_vacuum('idx_own_fts'::regclass) \gset
SELECT probe('H moves, VACUUM, then fts_vacuum');
CALL moves(:nmoves);
VACUUM own;
SELECT probe('I moves, VACUUM, no pack');
