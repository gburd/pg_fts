\set ON_ERROR_STOP on
SET client_min_messages = warning;
DROP TABLE IF EXISTS s;
CREATE TABLE s (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
SELECT setseed(:seed);
CREATE FUNCTION pg_temp.mk(n int) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg('w' || floor(power(random(), 2) * 3000)::int, ' ') FROM generate_series(1, n) $$;
INSERT INTO s SELECT g, pg_temp.mk(1 + floor(power(random(),3) * 400)::int) FROM generate_series(1, 20000) g;
CREATE INDEX s_fts ON s USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = :sc);
CREATE FUNCTION pg_temp.chk(label text) RETURNS text LANGUAGE sql AS $$
  SELECT format('%-28s N %s/%s  avgdl %s/%s  rel.err %s  segs %s', label,
     st.ndocs, t.n, round(st.avgdl::numeric, 4), round(t.a, 4),
     round(abs(st.avgdl::numeric - t.a) / t.a, 6), fts_index_nsegments('s_fts'))
  FROM fts_index_stats('s_fts') st,
       (SELECT count(*) n, avg(ftsdoc_length(to_ftsdoc('simple', body)))::numeric a FROM s) t $$;
SELECT pg_temp.chk('built');
-- churn: delete a random 20%, insert new rows of a different length mix, vacuum; repeat
DO $$ DECLARE r int; BEGIN
  FOR r IN 1..4 LOOP
    DELETE FROM s WHERE random() < 0.2 OR (r % 2 = 0 AND id % 3 = 0 AND random() < 0.5);
    INSERT INTO s SELECT 100000 * r + g, pg_temp.mk(CASE WHEN r % 2 = 1 THEN 1 + floor(random()*20)::int ELSE 200 + floor(random()*300)::int END)
      FROM generate_series(1, 3000) g;
  END LOOP; END $$;
SELECT pg_temp.chk('churned, before VACUUM');
VACUUM s;
SELECT pg_temp.chk('VACUUM 1');
DELETE FROM s WHERE length(body) > 1500;
VACUUM s;
SELECT pg_temp.chk('long rows deleted, VACUUM 2');
SELECT fts_merge('s_fts') IS NOT NULL AS merged \gset
SELECT pg_temp.chk('fts_merge');
DELETE FROM s WHERE random() < 0.3;
VACUUM s;
SELECT pg_temp.chk('30% deleted, VACUUM 3');
SELECT fts_vacuum('s_fts') IS NOT NULL AS v \gset
SELECT pg_temp.chk('fts_vacuum');
REINDEX INDEX s_fts;
SELECT pg_temp.chk('REINDEX');
