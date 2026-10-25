-- 2. Thorough: the 50 most common terms, both directions.  Reads the whole table once
--    (to_ftsdoc on every row); missing_rows are matching rows the index does not return.
CREATE TEMP TABLE fts_truth AS SELECT ctid AS tid, to_ftsdoc('english', message) AS d FROM ag;
CREATE TEMP TABLE fts_terms AS
  SELECT word FROM ts_stat('SELECT to_tsvector(''english'', message) FROM ag')
   WHERE word ~ '^[a-z0-9]+$' ORDER BY ndoc DESC LIMIT 50;
SET enable_seqscan = off;
SELECT sum(false_rows) AS false_rows, sum(heap_rows - (index_rows - false_rows)) AS missing_rows,
       count(*) FILTER (WHERE false_rows > 0 OR index_rows - false_rows <> heap_rows) AS bad_terms,
       count(*) AS terms_checked
FROM (SELECT
        (SELECT count(*) FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ w.word::ftsquery OFFSET 0) s) AS index_rows,
        (SELECT count(*) FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ w.word::ftsquery
                                 AND NOT fts_match(to_ftsdoc('english', message), w.word::ftsquery) OFFSET 0) s) AS false_rows,
        (SELECT count(*) FROM fts_truth WHERE fts_match(d, w.word::ftsquery)) AS heap_rows
      FROM fts_terms w) c;
RESET enable_seqscan;
