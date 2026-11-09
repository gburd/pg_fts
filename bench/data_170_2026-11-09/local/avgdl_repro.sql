\set ON_ERROR_STOP on
SET client_min_messages = warning;
DROP DATABASE IF EXISTS avg; CREATE DATABASE avg;
\c avg
SET client_min_messages = warning;
CREATE EXTENSION pg_fts;
CREATE TABLE t (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
INSERT INTO t SELECT g, (SELECT string_agg('w' || ((g * 7 + s) % 5000), ' ')
    FROM generate_series(1, CASE WHEN g % 2 = 0 THEN 10 ELSE 100 END) s)
  FROM generate_series(1, 200000) g;
CREATE INDEX t_fts ON t USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = :sc);
SELECT 'built' st, ndocs, round(avgdl::numeric,3) avgdl FROM fts_index_stats('t_fts'::regclass);
DELETE FROM t WHERE id % 2 = 1;
VACUUM t;
SELECT 'vacuum' st, ndocs, round(avgdl::numeric,3) avgdl FROM fts_index_stats('t_fts'::regclass);
SELECT fts_vacuum('t_fts'::regclass) AS fv;
SELECT 'fts_vacuum' st, ndocs, round(avgdl::numeric,3) avgdl FROM fts_index_stats('t_fts'::regclass);
SELECT fts_merge('t_fts'::regclass) AS fm;
SELECT 'fts_merge' st, ndocs, round(avgdl::numeric,3) avgdl FROM fts_index_stats('t_fts'::regclass);
REINDEX INDEX t_fts;
SELECT 'reindex' st, ndocs, round(avgdl::numeric,3) avgdl FROM fts_index_stats('t_fts'::regclass);
SELECT 'truth' st, count(*), round(avg(ftsdoc_length(to_ftsdoc('simple', body)))::numeric,3) FROM t;
