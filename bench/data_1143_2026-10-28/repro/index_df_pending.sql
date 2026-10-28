-- index_df_pending (1.14.3, Codeberg #10): fts_index_df counts pending
-- documents, as the ordering scan's IDF does.  Through 1.14.2 it summed the
-- segment dictionaries only, so a term held only by pending (not yet merged)
-- documents reported df = 1 -- the rarest term in the corpus -- while
-- fts_index_stats().ndocs and the ordering scan both counted those documents,
-- and the README recipe fts_bm25(doc, q, s.ndocs, s.avgdl, fts_index_df(idx, q))
-- disagreed with the scan's own score until the next flush.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE p (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
INSERT INTO p SELECT g, 'old' || (g % 10) FROM generate_series(1, 100) g;
CREATE INDEX p_fts ON p USING fts (to_ftsdoc('simple', body));
INSERT INTO p SELECT g, 'fresh word' FROM generate_series(101, 150) g;  -- pending
-- the reporter's repro: 50 rows hold 'fresh', all pending (1.14.2: {1,10})
SELECT ndocs, avgdl FROM fts_index_stats('p_fts');
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'fresh | old1')) AS df_pending;
-- a term in neither the segments nor the pending list still reports 1
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'nosuchterm | word | fresh')) AS df_absent;

-- the README recipe agrees with the ordering scan's own distance (the target
-- list <=> is the scan's exact distance) for every matching row, pending ones
-- included.  All doclens are < 8, so the doclen sidecar's quantization is exact.
CREATE FUNCTION pg_temp.recipe_vs_scan(qt text, OUT nrows bigint, OUT npending bigint,
                                      OUT max_abs_diff_ok bool) LANGUAGE sql AS $$
  WITH scan AS (
    SELECT id, to_ftsdoc('simple', body) <=> to_ftsquery('simple', qt) AS dist FROM p
     WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', qt)
     ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', qt) LIMIT 1000),
  recipe AS (
    SELECT id, 1.0 / (1.0 + fts_bm25(to_ftsdoc('simple', body), q, s.ndocs, s.avgdl,
                                     fts_index_df('p_fts', q))) AS dist
      FROM p, fts_index_stats('p_fts') s, to_ftsquery('simple', qt) q
     WHERE to_ftsdoc('simple', body) @@@ q)
  SELECT count(*), count(*) FILTER (WHERE scan.id > 100),
         max(abs(scan.dist - recipe.dist)) < 1e-12
    FROM scan JOIN recipe USING (id) $$;
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT 'before merge' AS state, * FROM pg_temp.recipe_vs_scan('fresh | old1');
SELECT 'before merge' AS state, * FROM pg_temp.recipe_vs_scan('fresh');
SELECT fts_merge('p_fts') AS merged;
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'fresh | old1')) AS df_merged;
SELECT 'after merge' AS state, * FROM pg_temp.recipe_vs_scan('fresh | old1');
-- mixed: segment and pending copies of one term are summed
INSERT INTO p SELECT g, 'fresh old1' FROM generate_series(151, 170) g;
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'fresh | old1')) AS df_mixed;
SELECT 'mixed' AS state, * FROM pg_temp.recipe_vs_scan('fresh | old1');
RESET enable_seqscan; RESET enable_bitmapscan;
DROP TABLE p;
