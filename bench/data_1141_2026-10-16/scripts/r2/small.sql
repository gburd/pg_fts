SET client_min_messages = warning;
SET pg_fts.pending_flush_threshold = 0;
CREATE TABLE ps (id int, body text) WITH (autovacuum_enabled = off);
INSERT INTO ps SELECT g, 'tiny w' || g FROM generate_series(1, 10) g;
CREATE INDEX ps_fts ON ps USING fts (to_ftsdoc('simple', body));
INSERT INTO ps SELECT g, 'common w' || (g % 40) || CASE WHEN g % 1000 = 7 THEN ' tiny' ELSE '' END FROM generate_series(11, 4010) g;
ANALYZE ps;
\pset format unaligned
\pset tuples_only on
EXPLAIN SELECT id FROM ps WHERE to_ftsdoc('simple', body) @@@ 'tiny'::ftsquery LIMIT 20;
SELECT 'actual=' || count(*) FROM ps WHERE to_ftsdoc('simple', body) @@@ 'tiny'::ftsquery;
