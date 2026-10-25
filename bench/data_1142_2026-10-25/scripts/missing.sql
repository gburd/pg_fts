-- CHANGELOG 1.14.2 "How to check an index", step 2 (missing matches), verbatim with t=ag body=message,
-- plus step 1 for the same term so the subtraction can be done.
\timing on
SET enable_seqscan = off;
SELECT count(*) AS index_count FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message)
                         @@@ to_ftsquery('english', 'vacuum') OFFSET 0) s;
SELECT count(*) AS false_rows FROM (
         SELECT 1 FROM ag
          WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', 'vacuum')
            AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', 'vacuum'))
         OFFSET 0) s;
RESET enable_seqscan;
SELECT count(*) AS heap_count FROM ag WHERE fts_match(to_ftsdoc('english', message),
                                       to_ftsquery('english', 'vacuum'));
