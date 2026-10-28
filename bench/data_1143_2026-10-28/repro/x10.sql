SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE p (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
INSERT INTO p SELECT g, 'old' || (g % 10) || ' apple' FROM generate_series(1, 100) g;
CREATE INDEX p_fts ON p USING fts (to_ftsdoc('simple', body));
INSERT INTO p SELECT g, 'fresh apple' FROM generate_series(101, 150) g;  -- pending
-- ranked prefix query (modifier path, bm25_topk_exact) vs the same query once merged
CREATE TEMP TABLE b AS SELECT p.id, r.score FROM fts_search('p_fts', to_ftsquery('simple', 'fresh | old1 | app:*'), 1000) r JOIN p ON p.ctid = r.ctid;
CREATE TEMP TABLE bn AS SELECT p.id, r.score FROM fts_search('p_fts', to_ftsquery('simple', 'fresh | old1'), 1000) r JOIN p ON p.ctid = r.ctid;
SELECT fts_merge('p_fts');
CREATE TEMP TABLE a AS SELECT p.id, r.score FROM fts_search('p_fts', to_ftsquery('simple', 'fresh | old1 | app:*'), 1000) r JOIN p ON p.ctid = r.ctid;
CREATE TEMP TABLE an AS SELECT p.id, r.score FROM fts_search('p_fts', to_ftsquery('simple', 'fresh | old1'), 1000) r JOIN p ON p.ctid = r.ctid;
SELECT 'prefix(modifier) before=after' AS c, count(*), bool_and(abs(a.score - b.score) < 1e-9), max(abs(a.score-b.score)) FROM a JOIN b USING (id);
SELECT 'plain before=after' AS c, count(*), bool_and(abs(an.score - bn.score) < 1e-9), max(abs(an.score-bn.score)) FROM an JOIN bn USING (id);
