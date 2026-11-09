\set ON_ERROR_STOP on
SET client_min_messages = warning;
DROP TABLE IF EXISTS rk;
CREATE TABLE rk (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
SELECT setseed(0.3);
INSERT INTO rk SELECT g, (SELECT string_agg('w' || floor(power(random(), 2) * 2000)::int, ' ')
    FROM generate_series(1, CASE WHEN g % 2 = 0 THEN 5 + (g % 20) ELSE 80 + (g % 60) END) s WHERE g > 0)
  FROM generate_series(1, 40000) g;
CREATE INDEX rk_fts ON rk USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = :sc);
DELETE FROM rk WHERE id % 2 = 1;
VACUUM rk;
SELECT fts_vacuum('rk_fts') AS v \gset
SELECT 'stats', ndocs, round(avgdl::numeric,3) FROM fts_index_stats('rk_fts');
SET enable_seqscan = off;
\o :out
SELECT q, string_agg(id::text || ':' || round(score::numeric, 6), ',' ORDER BY rn) FROM (
  SELECT q, id, score, row_number() OVER (PARTITION BY q ORDER BY score DESC, id) rn FROM
    (VALUES ('w5'),('w100'),('w1500'),('w3 | w700'),('w10 & w20')) v(q),
    LATERAL (SELECT r.id, s.score FROM fts_search('rk_fts', q::ftsquery, 20) s JOIN rk r ON r.ctid = s.ctid) x) y
  GROUP BY q ORDER BY q;
\o
REINDEX INDEX rk_fts;
\o :outr
SELECT q, string_agg(id::text || ':' || round(score::numeric, 6), ',' ORDER BY rn) FROM (
  SELECT q, id, score, row_number() OVER (PARTITION BY q ORDER BY score DESC, id) rn FROM
    (VALUES ('w5'),('w100'),('w1500'),('w3 | w700'),('w10 & w20')) v(q),
    LATERAL (SELECT r.id, s.score FROM fts_search('rk_fts', q::ftsquery, 20) s JOIN rk r ON r.ctid = s.ctid) x) y
  GROUP BY q ORDER BY q;
\o
