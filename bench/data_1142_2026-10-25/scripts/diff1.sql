\set ON_ERROR_STOP 1
SET client_min_messages = warning;
SET enable_seqscan = off; SET enable_indexscan = off;
CREATE TEMP TABLE bm AS SELECT ctid AS tid FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', :'q');
SET enable_bitmapscan = off; SET enable_indexscan = on;
CREATE TEMP TABLE pi AS SELECT ctid AS tid FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', :'q');
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
CREATE TEMP TABLE tr AS SELECT tid FROM truthdoc WHERE fts_match(d, to_ftsquery('english', :'q'));
CREATE TEMP TABLE fpb AS SELECT tid FROM bm EXCEPT SELECT tid FROM tr;
SELECT format('%-18s truth %s | bitmap %s FP %s FN %s | idxscan %s FP %s FN %s | fts_count %s',
  :'q', (SELECT count(*) FROM tr),
  (SELECT count(*) FROM bm), (SELECT count(*) FROM fpb), (SELECT count(*) FROM (SELECT tid FROM tr EXCEPT SELECT tid FROM bm) x),
  (SELECT count(*) FROM pi), (SELECT count(*) FROM (SELECT tid FROM pi EXCEPT SELECT tid FROM tr) x), (SELECT count(*) FROM (SELECT tid FROM tr EXCEPT SELECT tid FROM pi) x),
  fts_count('idx_ag_msg_fts', to_ftsquery('english', :'q')));
SELECT format('  FP %s n=%s prev_true=%s next_true=%s rowpred=%s', f.tid, a.n,
  EXISTS (SELECT 1 FROM tr WHERE tr.tid = format('(%s,%s)', (f.tid::text::point)[0], (f.tid::text::point)[1]-1)::tid),
  EXISTS (SELECT 1 FROM tr WHERE tr.tid = format('(%s,%s)', (f.tid::text::point)[0], (f.tid::text::point)[1]+1)::tid),
  fts_match(to_ftsdoc('english', a.message), to_ftsquery('english', :'q')))
FROM fpb f JOIN ag a ON a.ctid = f.tid ORDER BY f.tid LIMIT 8;
