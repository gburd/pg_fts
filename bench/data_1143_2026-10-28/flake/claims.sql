-- verify two CHANGELOG 1.14.3 numbers on a given build: (a) 2000-term query + '{}' dfs -> NaN on 1.14.2;
-- (b) fts_search score change at fts_merge for 'fresh | old1 | app:*' (max abs diff), 150 rows.
\pset footer off
SELECT extversion AS ext FROM pg_extension WHERE extname = 'pg_fts';
SELECT fts_bm25(d, q, 1e12, 20, '{}'::float8[]) AS bm25_empty_dfs_2000terms,
       fts_bm25(d, q, 1e12, 20) AS bm25_null_dfs_2000terms
  FROM (SELECT to_ftsdoc('simple', string_agg('t' || g, ' ')) AS d,
               to_ftsquery('simple', string_agg('t' || g, ' | ')) AS q
          FROM generate_series(1, 2000) g) s;
DROP TABLE IF EXISTS pm;
CREATE TABLE pm (id int, body text) WITH (autovacuum_enabled = off);
INSERT INTO pm SELECT g, 'old' || (g % 10) || ' apple' FROM generate_series(1, 100) g;
CREATE INDEX pm_fts ON pm USING fts (to_ftsdoc('simple', body));
SET pg_fts.pending_flush_threshold = 0;
INSERT INTO pm SELECT g, 'fresh apple' FROM generate_series(101, 150) g;
CREATE TEMP TABLE b AS SELECT p.id, r.score FROM fts_search('pm_fts', to_ftsquery('simple', 'fresh | old1 | app:*'), 1000) r JOIN pm p ON p.ctid = r.ctid;
SELECT fts_merge('pm_fts') IS NOT NULL AS merged;
CREATE TEMP TABLE a AS SELECT p.id, r.score FROM fts_search('pm_fts', to_ftsquery('simple', 'fresh | old1 | app:*'), 1000) r JOIN pm p ON p.ctid = r.ctid;
SELECT count(*) AS rows_compared, round(max(abs(a.score - b.score))::numeric, 4) AS max_score_change_at_merge
  FROM a JOIN b USING (id);
DROP TABLE pm;
