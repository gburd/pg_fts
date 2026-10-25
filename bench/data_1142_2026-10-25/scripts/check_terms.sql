-- pg_fts index check (CHANGELOG 1.14.2).  Replace ag / message / 'english' / the term list
-- with your table, indexed text column and text search configuration.
-- 1. Quick: rows the index returns although their own document does not match.  Reads
--    only what the index returns.  Any non-zero false_rows means the index is wrong.
SET enable_seqscan = off;
SELECT t.q, (SELECT count(*) FROM (
          SELECT 1 FROM ag
           WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', t.q)
             AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', t.q))
          OFFSET 0) s) AS false_rows
FROM unnest(ARRAY['vacuum', 'visibility & map', 'hash & index', 'freeze']) AS t(q);
RESET enable_seqscan;
