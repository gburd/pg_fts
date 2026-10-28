SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE p (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
INSERT INTO p SELECT g, 'old' || (g % 10) FROM generate_series(1, 100) g;
CREATE INDEX p_fts ON p USING fts (to_ftsdoc('simple', body));
INSERT INTO p SELECT g, 'fresh word' FROM generate_series(101, 150) g;
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT * FROM fts_index_stats('p_fts');
EXPLAIN (VERBOSE, COSTS OFF) SELECT id, to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') AS dist FROM p
     WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', 'fresh | old1')
     ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') LIMIT 1000;
SELECT id, to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') AS dist FROM p
     WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', 'fresh | old1')
     ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') LIMIT 3;
SELECT id, 1.0 / (1.0 + fts_bm25(to_ftsdoc('simple', body), q, s.ndocs, s.avgdl, fts_index_df('p_fts', q))) AS dist, fts_index_df('p_fts', q)
      FROM p, fts_index_stats('p_fts') s, to_ftsquery('simple', 'fresh | old1') q
     WHERE to_ftsdoc('simple', body) @@@ q AND id IN (1, 11, 101, 102) ORDER BY id;
SELECT * FROM fts_search('p_fts', to_ftsquery('simple', 'fresh | old1'), 3);
SELECT fts_merge('p_fts');
SELECT id, to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') AS dist FROM p
     WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', 'fresh | old1')
     ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'fresh | old1') LIMIT 3;
SELECT id, 1.0 / (1.0 + fts_bm25(to_ftsdoc('simple', body), q, s.ndocs, s.avgdl, fts_index_df('p_fts', q))) AS dist
      FROM p, fts_index_stats('p_fts') s, to_ftsquery('simple', 'fresh | old1') q
     WHERE to_ftsdoc('simple', body) @@@ q AND id IN (1, 11, 101, 102) ORDER BY id;
