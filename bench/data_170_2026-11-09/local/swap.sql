\set ON_ERROR_STOP on
SET client_min_messages = warning;
DROP TABLE IF EXISTS sw;
CREATE TABLE sw (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
SELECT setseed(0.5);
INSERT INTO sw SELECT g, (SELECT string_agg('w' || floor(random()*900)::int, ' ') FROM generate_series(1, 1 + floor(power(random(),2)*300)::int) s WHERE g > 0) FROM generate_series(1, 12000) g;
CREATE INDEX sw_fts ON sw USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = :a);
SET pg_fts.pending_flush_threshold = 400;
INSERT INTO sw SELECT g, (SELECT string_agg('w' || floor(random()*900)::int, ' ') FROM generate_series(1, 1 + floor(power(random(),2)*300)::int) s WHERE g > 0) FROM generate_series(20001, 24000) g;
RESET pg_fts.pending_flush_threshold;
ALTER INDEX sw_fts SET (doclen_sidecar = :b);
DELETE FROM sw WHERE id % 3 = 0; VACUUM sw;
SELECT fts_merge('sw_fts') IS NOT NULL AS m \gset
SELECT format('after merge: N %s avgdl %s', ndocs, round(avgdl::numeric,3)) FROM fts_index_stats('sw_fts');
SELECT format('truth: %s %s', count(*), round(avg(ftsdoc_length(to_ftsdoc('simple', body)))::numeric,3)) FROM sw;
DELETE FROM sw WHERE id % 5 = 0; VACUUM sw;
DELETE FROM sw WHERE id % 7 = 0; VACUUM sw;
SELECT format('%s->%s: N %s/%s avgdl %s/%s err %s%%', :'a', :'b', s.ndocs, t.n, round(s.avgdl::numeric,3), round(t.a,3), round(100*abs(s.avgdl::numeric-t.a)/t.a, 3))
  FROM fts_index_stats('sw_fts') s, (SELECT count(*) n, avg(ftsdoc_length(to_ftsdoc('simple', body)))::numeric a FROM sw) t;
