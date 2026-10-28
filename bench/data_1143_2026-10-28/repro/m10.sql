-- #10 measurement: README recipe vs the ORDERING INDEX SCAN's own distance for each row
-- (fts_current_distance() = the distance bm25_gettuple computed for the tuple it returned;
-- internal function, read here only as an instrument).  Reporter's repro corpus.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
SELECT extversion FROM pg_extension WHERE extname = 'pg_fts';
CREATE TABLE p (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
INSERT INTO p SELECT g, 'old' || (g % 10) FROM generate_series(1, 100) g;
CREATE INDEX p_fts ON p USING fts (to_ftsdoc('simple', body));
INSERT INTO p SELECT g, 'fresh word' FROM generate_series(101, 150) g;
SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE FUNCTION cmp(qt text, label text) RETURNS TABLE (state text, q text, nrows bigint, npending bigint, max_abs_diff float8, n_differ bigint)
LANGUAGE sql AS $$
  WITH scan AS (
    SELECT id, fts_current_distance() AS sdist FROM p
     WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', qt)
     ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', qt) LIMIT 1000),
  recipe AS (
    SELECT id, 1.0 / (1.0 + fts_bm25(to_ftsdoc('simple', body), qq, s.ndocs, s.avgdl, fts_index_df('p_fts', qq))) AS rdist
      FROM p, fts_index_stats('p_fts') s, to_ftsquery('simple', qt) qq)
  SELECT label, qt, count(*), count(*) FILTER (WHERE id > 100), max(abs(sdist - rdist)),
         count(*) FILTER (WHERE abs(sdist - rdist) > 1e-12)
    FROM scan JOIN recipe USING (id) $$;
EXPLAIN (COSTS OFF) SELECT id, fts_current_distance() FROM p WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', 'fresh | old1')
  ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') LIMIT 1000;
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'fresh | old1')) AS df_before_merge;
SELECT * FROM cmp('fresh | old1', 'before merge');
SELECT * FROM cmp('fresh', 'before merge');
SELECT * FROM cmp('old1', 'before merge');
SELECT fts_merge('p_fts') AS merged;
SELECT fts_index_df('p_fts', to_ftsquery('simple', 'fresh | old1')) AS df_after_merge;
SELECT * FROM cmp('fresh | old1', 'after merge');
SELECT * FROM cmp('fresh', 'after merge');
SELECT * FROM cmp('old1', 'after merge');
