-- of the 383 post-upgrade false rows: each sits in a heap slot; was that slot's dying occupant a 1.10.0-era
-- aborted row? (an aborted row's slot at its abort time is unknown, so check the cheaper invariant: every
-- post-upgrade false row is in a heap block that already existed when the 1.10.0 phase ended)
SET enable_seqscan = off; SET enable_indexscan = off;
CREATE TEMP TABLE fpv AS SELECT ctid AS tid, id FROM ag
 WHERE to_ftsdoc('english', message) @@@ 'vacuum'::ftsquery AND NOT fts_match(to_ftsdoc('english', message), 'vacuum'::ftsquery);
RESET enable_seqscan; RESET enable_indexscan;
SELECT format('post-upgrade false rows %s, max heap block %s (1.10.0 phase ended at heap_pages 131286)',
  count(*), max((tid::text::point)[0]))
FROM fpv, (SELECT id AS cut FROM ag ORDER BY id OFFSET 1905299 LIMIT 1) x WHERE id > x.cut;
