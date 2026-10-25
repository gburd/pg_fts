-- C1: are the post-upgrade false rows new heap rows in slots that 1.10.0-era entries point at?
SET enable_seqscan = off; SET enable_indexscan = off;
CREATE TEMP TABLE fpv AS SELECT ctid AS tid, id FROM ag
 WHERE to_ftsdoc('english', message) @@@ 'vacuum'::ftsquery AND NOT fts_match(to_ftsdoc('english', message), 'vacuum'::ftsquery);
RESET enable_seqscan; RESET enable_indexscan;
SELECT format('false rows %s; rows inserted after the upgrade (id above the 1,905,300th committed id) %s; before %s',
  count(*), count(*) FILTER (WHERE id > x.cut), count(*) FILTER (WHERE id <= x.cut))
FROM fpv, (SELECT id AS cut FROM ag ORDER BY id OFFSET 1905299 LIMIT 1) x;
