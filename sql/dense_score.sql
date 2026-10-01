-- dense_score: a single-term, single-segment ranked query on a high-df term is
-- scored exhaustively (fts_search_dense1, 1.9.0) instead of with WAND.  It must
-- return exactly what WAND returns -- ids, order and distances -- for every k,
-- with ties, after deletes (tombstones), and through fts_search().
SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
CREATE TABLE dsc (id int PRIMARY KEY, d ftsdoc);
-- 'com' in every doc; lengths vary so scores vary; many exact ties
INSERT INTO dsc SELECT g, to_ftsdoc('simple', 'com ' || repeat('com ', g % 3) || repeat('f' || (g % 5) || ' ', g % 17))
FROM generate_series(1, 6000) g;
CREATE INDEX dsc_fts ON dsc USING fts (d);
VACUUM ANALYZE dsc;

CREATE FUNCTION dsc_same(k int) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE w text; dn text; f1 text; f2 text;
BEGIN
  SET LOCAL pg_fts.dense_score_min_df = 0;
  SELECT string_agg(id || ':' || (d <=> to_ftsquery('simple','com'))::text, ',') INTO w
    FROM (SELECT id, d FROM dsc WHERE d @@@ to_ftsquery('simple','com') ORDER BY d <=> to_ftsquery('simple','com') LIMIT k) s;
  SELECT string_agg(ctid::text || ':' || score::text, ',') INTO f1 FROM fts_search('dsc_fts', to_ftsquery('simple','com'), k);
  SET LOCAL pg_fts.dense_score_min_df = 1;
  SELECT string_agg(id || ':' || (d <=> to_ftsquery('simple','com'))::text, ',') INTO dn
    FROM (SELECT id, d FROM dsc WHERE d @@@ to_ftsquery('simple','com') ORDER BY d <=> to_ftsquery('simple','com') LIMIT k) s;
  SELECT string_agg(ctid::text || ':' || score::text, ',') INTO f2 FROM fts_search('dsc_fts', to_ftsquery('simple','com'), k);
  RETURN w IS NOT NULL AND w = dn AND f1 = f2;
END $$;

SELECT bool_and(dsc_same(k)) AS dense_equals_wand
FROM (VALUES (1), (2), (10), (100), (999), (6000)) ks(k);

-- tombstones: deleted docs must be skipped by the dense loop exactly as by WAND
DELETE FROM dsc WHERE id % 7 = 0;
VACUUM dsc;
SELECT bool_and(dsc_same(k)) AS dense_equals_wand_after_delete
FROM (VALUES (1), (10), (100), (5000)) ks(k);
SELECT count(*) AS live_ranked FROM (SELECT id FROM dsc WHERE d @@@ to_ftsquery('simple','com')
  ORDER BY d <=> to_ftsquery('simple','com')) s;

DROP FUNCTION dsc_same(int);
DROP TABLE dsc;
