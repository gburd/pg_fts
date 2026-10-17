\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pageinspect;
SELECT 'pg_fts ' || extversion AS ver FROM pg_extension WHERE extname = 'pg_fts';
CREATE TABLE docs (id int PRIMARY KEY, body text);
INSERT INTO docs SELECT g,
  'common w' || (g % 1000) || ' x' || (g % 7) ||
  CASE WHEN g % 1000 = 0 THEN ' rare' ELSE '' END
  FROM generate_series(1, :rows) g;
CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE docs;
-- pending: :pend more rows; flush threshold 0 + autovacuum off keep them pending.
-- 'fresh' occurs ONLY in pending rows; 'rare' also gets pending occurrences.
INSERT INTO docs SELECT g,
  'common fresh w' || (g % 1000) || ' x' || (g % 7) ||
  CASE WHEN g % 1000 = 0 THEN ' rare' ELSE '' END
  FROM generate_series(:rows + 1, :rows + :pend) g;
ANALYZE docs;
CREATE FUNCTION meta_u32(off int) RETURNS bigint LANGUAGE sql AS $$
  SELECT get_byte(p, off)::bigint + get_byte(p, off+1)*256 + get_byte(p, off+2)*65536 + get_byte(p, off+3)::bigint*16777216
  FROM get_raw_page('docs_fts', 0) p $$;
SELECT fts_index_nsegments('docs_fts') AS nseg, meta_u32(60) AS npending,
       (SELECT reltuples FROM pg_class WHERE relname = 'docs') AS reltuples;
CREATE FUNCTION est(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE ln text; r text; n text; pc text; act bigint;
BEGIN
  FOR ln IN EXECUTE format('EXPLAIN SELECT id FROM docs WHERE to_ftsdoc(''simple'', body) @@@ %L::ftsquery', q) LOOP
    IF r IS NULL THEN r := (regexp_match(ln, 'rows=(\d+)'))[1]; n := btrim(split_part(ln, '  (', 1)); END IF;
  END LOOP;
  FOR ln IN EXECUTE format('EXPLAIN SELECT count(*) FROM docs WHERE to_ftsdoc(''simple'', body) @@@ %L::ftsquery', q) LOOP
    IF ln ~ '(Scan|Custom)' AND pc IS NULL THEN pc := btrim(regexp_replace(split_part(ln, '  (', 1), '^\s*->\s*', '')); END IF;
  END LOOP;
  EXECUTE format('SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc(''simple'', body), %L::ftsquery)', q) INTO act;
  RETURN format('%-22s est=%-7s actual=%-7s select-plan=%-45s count-plan=%s', q, r, act, n, pc);
END $$;
SELECT est(q) FROM unnest(ARRAY['rare','common','fresh','nosuchterm','rare & x3','rare | x3','!rare','rare & !x3',
  '"common rare"','"w5 x5"','rar*','rare~1','rare:A']) q;
EXPLAIN (COSTS OFF) SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery
  ORDER BY to_ftsdoc('simple', body) <=> 'rare'::ftsquery LIMIT 20;
-- execution time of the reporter's query shape (count of a rare term), 3 runs in one session
SELECT 1 FROM docs LIMIT 1;
