-- run while the flusher is stopped between bm25_add_segment_with_room and the pending-list clear
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT (fts_index_stats('dp_fts')).*;
SELECT count(*) AS ranked_rows, count(DISTINCT id) AS distinct_ids
  FROM (SELECT id FROM dp WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery
         ORDER BY to_ftsdoc('simple', body) <=> 'fresh'::ftsquery LIMIT 1000) s;
SELECT count(*) AS ranked_rows_apple, count(DISTINCT id) AS distinct_ids_apple
  FROM (SELECT id FROM dp WHERE to_ftsdoc('simple', body) @@@ 'apple'::ftsquery
         ORDER BY to_ftsdoc('simple', body) <=> 'apple'::ftsquery LIMIT 1000) s;
SELECT count(*) AS fts_search_rows, count(DISTINCT ctid) AS fts_search_distinct
  FROM fts_search('dp_fts', 'fresh'::ftsquery, 1000);
SELECT fts_index_df('dp_fts', 'fresh | apple'::ftsquery) AS df;
SELECT count(*) AS where_count FROM dp WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery;
-- modifier query (bm25_topk_exact path) and WHERE + ORDER BY
SELECT count(*) AS prefix_ranked_rows, count(DISTINCT id) AS prefix_distinct
  FROM (SELECT id FROM dp WHERE to_ftsdoc('simple', body) @@@ 'fre:*'::ftsquery
         ORDER BY to_ftsdoc('simple', body) <=> 'fre:*'::ftsquery LIMIT 1000) s;
SELECT count(*) AS and_ranked_rows, count(DISTINCT id) AS and_distinct
  FROM (SELECT id FROM dp WHERE to_ftsdoc('simple', body) @@@ 'fresh & apple'::ftsquery
         ORDER BY to_ftsdoc('simple', body) <=> 'fresh & apple'::ftsquery LIMIT 1000) s;
SELECT count(*) AS top10_rows, count(DISTINCT id) AS top10_distinct
  FROM (SELECT id FROM dp WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery
         ORDER BY to_ftsdoc('simple', body) <=> 'fresh'::ftsquery LIMIT 10) s;
