SET client_min_messages=warning;
DROP TABLE IF EXISTS dp;
CREATE TABLE dp (id int, d ftsdoc);
INSERT INTO dp SELECT g, to_ftsdoc('simple', repeat('cherry ', 1 + g % 7) || 'pad' || (g % 5))
  FROM generate_series(1, 2000) g;
CREATE INDEX dp_fts ON dp USING fts (d);
DELETE FROM dp WHERE id % 10 = 0;
INSERT INTO dp SELECT g, to_ftsdoc('simple', repeat('cherry ', 1 + g % 7) || 'pad' || (g % 5))
  FROM generate_series(1, 2000) g WHERE g % 10 = 0;
VACUUM ANALYZE dp;
SELECT fts_index_nsegments('dp_fts') AS nseg, (SELECT count(*) FROM dp) AS nrows,
       (SELECT count(*) FROM dp WHERE d @@@ 'cherry'::ftsquery) AS nmatch;
SET enable_seqscan=off; SET enable_bitmapscan=off;
EXPLAIN (COSTS OFF) SELECT id FROM dp WHERE d @@@ 'cherry'::ftsquery ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000;
SELECT count(*) AS rows, count(DISTINCT id) AS distinct_ids FROM
  (SELECT id FROM dp WHERE d @@@ 'cherry'::ftsquery ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000) s;
SELECT count(*) AS srf_rows, count(DISTINCT ctid) AS srf_distinct FROM fts_search('dp_fts','cherry'::ftsquery,100000);
-- prefix consistency: LIMIT 10/100/1000 against the full ordered pull
CREATE TEMP TABLE full_o AS SELECT row_number() OVER () rn, id, dist FROM
  (SELECT id, d <=> 'cherry'::ftsquery AS dist FROM dp WHERE d @@@ 'cherry'::ftsquery ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000) s;
SELECT k,
  (SELECT count(DISTINCT id) FROM (SELECT id FROM dp WHERE d @@@ 'cherry'::ftsquery ORDER BY d <=> 'cherry'::ftsquery LIMIT k) s) AS distinct_at_k,
  (SELECT array_agg(round(dist::numeric,12)) FROM (SELECT d <=> 'cherry'::ftsquery dist FROM dp WHERE d @@@ 'cherry'::ftsquery ORDER BY d <=> 'cherry'::ftsquery LIMIT k) s)
   = (SELECT array_agg(round(dist::numeric,12) ORDER BY rn) FROM (SELECT * FROM full_o WHERE rn <= k) s) AS dist_prefix_eq
FROM unnest(ARRAY[10,100,1000,1800]) k;
-- exhaustive oracle: score every matching row via fts_search (SRF) and compare the multiset of scores of the first k
CREATE TEMP TABLE oracle AS SELECT row_number() OVER (ORDER BY score DESC, ctid) rn, ctid, score FROM fts_search('dp_fts','cherry'::ftsquery,100000);
SELECT k,
 (SELECT array_agg(round((1/(1+score))::numeric,12) ORDER BY rn) FROM oracle WHERE rn<=k)
 = (SELECT array_agg(round(dist::numeric,12)) FROM (SELECT d <=> 'cherry'::ftsquery dist FROM dp WHERE d @@@ 'cherry'::ftsquery ORDER BY d <=> 'cherry'::ftsquery LIMIT k) s) AS dists_match_oracle,
 (SELECT array_agg(ctid ORDER BY rn) FROM oracle WHERE rn<=k)
 = (SELECT array_agg(ctid) FROM (SELECT ctid FROM dp WHERE d @@@ 'cherry'::ftsquery ORDER BY d <=> 'cherry'::ftsquery LIMIT k) s) AS ctids_match_oracle_tidorder
FROM unnest(ARRAY[10,100,1000,1800]) k;
