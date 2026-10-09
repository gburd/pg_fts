-- dict_dir: the cached dictionary-index directory (1.12.0, ROADMAP I7) must find
-- exactly the dictionary page the on-disk chain walk finds, for every term:
-- first and last in sort order, terms equal to an index page's first term,
-- prefixes of indexed terms, absent terms between and beyond, several segments,
-- a merge (directory rebuilt in the same backend), and with the cache disabled
-- (pg_fts.doclen_cache_mb = 0, the chain walk).
SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;

-- enough distinct terms for a multi-page dictionary index (~120 dict pages)
CREATE TABLE dd (id int PRIMARY KEY, d ftsdoc);
INSERT INTO dd SELECT g, to_ftsdoc('simple', 't' || lpad(g::text, 6, '0') || ' common '
                                   || CASE WHEN g % 10 = 0 THEN 'tenth' ELSE '' END)
FROM generate_series(1, 30000) g;
CREATE INDEX dd_fts ON dd USING fts (d);
VACUUM ANALYZE dd;

-- ranked top-k ids for a term, under a given doclen_cache_mb
CREATE FUNCTION dd_ids(q text, mb int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE format('SET LOCAL pg_fts.doclen_cache_mb = %s', mb);
  EXECUTE format('SELECT coalesce(string_agg(id::text, '','' ORDER BY rn), ''-'')
                  FROM (SELECT id, row_number() OVER () rn FROM
                        (SELECT id FROM dd WHERE d @@@ to_ftsquery(''simple'',%L)
                         ORDER BY d <=> to_ftsquery(''simple'',%L), id LIMIT 5) s) z', q, q) INTO r;
  RETURN r;
END $$;

-- every probe: cached directory == chain walk, and the expected hit/miss
CREATE TABLE probes (q text, want_hit bool);
INSERT INTO probes VALUES
  ('t000001', true), ('t030000', true), ('t015000', true), ('t000255', true),
  ('t000256', true), ('t029999', true), ('common', true), ('tenth', true),
  ('a', false), ('t', false), ('t00000', false), ('t0000011', false),
  ('t030001', false), ('zzzz', false), ('t015000x', false), ('s999999', false);

SELECT q, dd_ids(q, 64) = dd_ids(q, 0) AS same, (dd_ids(q, 64) <> '-') = want_hit AS expected
FROM probes ORDER BY q;

-- the dictionary index really has several pages (the test means nothing otherwise)
SELECT (SELECT nterms FROM fts_index_stats('dd_fts')) > 20000 AS many_terms;

-- a second segment with new terms; the same backend must see them after the merge
-- (the directory is rebuilt when the metapage generation moves)
SELECT dd_ids('newseg000001', 64) AS before_insert;
INSERT INTO dd SELECT 100000 + g, to_ftsdoc('simple', 'newseg' || lpad(g::text, 6, '0') || ' common')
FROM generate_series(1, 5000) g;
SELECT fts_merge('dd_fts') IS NOT NULL AS merged;
SELECT dd_ids('newseg000001', 64) AS after_merge_hit,
       dd_ids('newseg000001', 64) = dd_ids('newseg000001', 0) AS same_new,
       dd_ids('t000001', 64) = dd_ids('t000001', 0) AS same_old,
       dd_ids('common', 64) = dd_ids('common', 0) AS same_common;

-- multiple segments listed at once (pending flushed into its own segment)
INSERT INTO dd SELECT 200000 + g, to_ftsdoc('simple', 'third' || g || ' common')
FROM generate_series(1, 2000) g;
VACUUM dd;
SELECT fts_index_nsegments('dd_fts') >= 1 AS segs,
       dd_ids('third1', 64) = dd_ids('third1', 0) AS same_third,
       dd_ids('t029999', 64) = dd_ids('t029999', 0) AS same_old2,
       dd_ids('third1', 64) <> '-' AS third_found;

DROP TABLE probes;
DROP TABLE dd;
DROP FUNCTION dd_ids(text, int);
