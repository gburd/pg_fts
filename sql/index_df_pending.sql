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

-- the README recipe agrees with the ranked engine's own score for every
-- matching row, pending ones included.  fts_search() returns the score of the
-- engine the ordering scan runs (bm25_topk_visible); a visible `d <=> q` in a
-- target list is the corpus-free fts_distance() fallback, so it is not the
-- oracle.  All doclens are < 8, so the doclen sidecar's quantization is exact.
CREATE FUNCTION pg_temp.recipe_vs_scan(qt text, OUT nrows bigint, OUT npending bigint,
                                      OUT agree bool) LANGUAGE sql AS $$
  WITH scan AS (
    SELECT p.id, r.score FROM fts_search('p_fts', to_ftsquery('simple', qt), 1000) r
      JOIN p ON p.ctid = r.ctid),
  recipe AS (
    SELECT id, fts_bm25(to_ftsdoc('simple', body), q, s.ndocs, s.avgdl,
                        fts_index_df('p_fts', q)) AS score
      FROM p, fts_index_stats('p_fts') s, to_ftsquery('simple', qt) q
     WHERE to_ftsdoc('simple', body) @@@ q)
  SELECT count(*), count(*) FILTER (WHERE id > 100),
         count(*) = (SELECT count(*) FROM recipe)
         AND max(abs(scan.score - recipe.score)) < 1e-9
    FROM scan JOIN recipe USING (id) $$;
-- and along the ordering index scan's own row order the recipe score never
-- increases (1.14.2: the pending-only term scored as df = 1 and jumped ahead)
CREATE FUNCTION pg_temp.recipe_follows_scan_order(qt text) RETURNS bool LANGUAGE sql AS $$
  WITH ord AS (
    SELECT id, row_number() OVER () AS rn FROM (
      SELECT id FROM p WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', qt)
       ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', qt) LIMIT 1000) x),
  rs AS (
    SELECT ord.rn, fts_bm25(to_ftsdoc('simple', body), q, s.ndocs, s.avgdl,
                            fts_index_df('p_fts', q)) AS score
      FROM ord JOIN p USING (id), fts_index_stats('p_fts') s, to_ftsquery('simple', qt) q)
  SELECT count(*) > 0 AND bool_and(prev IS NULL OR score <= prev + 1e-9)
    FROM (SELECT score, lag(score) OVER (ORDER BY rn) AS prev FROM rs) z $$;
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT 'before merge' AS state, * FROM pg_temp.recipe_vs_scan('fresh | old1');
SELECT 'before merge' AS state, * FROM pg_temp.recipe_vs_scan('fresh');
SELECT pg_temp.recipe_follows_scan_order('fresh | old1') AS before_merge_order_ok;
EXPLAIN (COSTS OFF) SELECT id FROM p WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', 'fresh | old1')
 ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') LIMIT 1000;
SELECT fts_merge('p_fts') AS merged;
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'fresh | old1')) AS df_merged;
SELECT 'after merge' AS state, * FROM pg_temp.recipe_vs_scan('fresh | old1');
-- mixed: segment and pending copies of one term are summed
INSERT INTO p SELECT g, 'fresh old1' FROM generate_series(151, 170) g;
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'fresh | old1')) AS df_mixed;
SELECT 'mixed' AS state, * FROM pg_temp.recipe_vs_scan('fresh | old1');
SELECT pg_temp.recipe_follows_scan_order('fresh | old1') AS mixed_order_ok;
RESET enable_seqscan; RESET enable_bitmapscan;
DROP TABLE p;

-- the same pending share in the ranked path for a prefix/fuzzy/regex/weighted
-- query (bm25_topk_exact): through 1.14.2 its idf used the segment df only, so
-- a pending-only term ranked as df = 0 and the scores changed at the flush.
-- Oracle: each query's ranked ids and scores before the merge equal after.
CREATE TABLE pm (id int, body text) WITH (autovacuum_enabled = off);
INSERT INTO pm SELECT g, 'old' || (g % 10) || ' apple' FROM generate_series(1, 100) g;
CREATE INDEX pm_fts ON pm USING fts (to_ftsdoc('simple', body));
INSERT INTO pm SELECT g, 'fresh apple' FROM generate_series(101, 150) g;   -- pending
CREATE TABLE pmq (q text);
INSERT INTO pmq VALUES ('fresh | old1 | app:*'), ('fresh & app:*'), ('fresh | olx1~1'), ('fresh:D | old1');
CREATE FUNCTION pg_temp.pm_ranked(qt text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(p.id || ':' || round(r.score::numeric, 9), ',' ORDER BY r.score DESC, p.id)
    FROM fts_search('pm_fts', to_ftsquery('simple', qt), 1000) r JOIN pm p ON p.ctid = r.ctid $$;
CREATE TEMP TABLE pm_before AS SELECT q, pg_temp.pm_ranked(q) AS r FROM pmq;
SELECT fts_merge('pm_fts') AS merged;
SELECT q, length(b.r) > 0 AS nonempty, b.r = pg_temp.pm_ranked(q) AS same_before_after_merge
  FROM pm_before b ORDER BY q;
DROP TABLE pm, pmq;
