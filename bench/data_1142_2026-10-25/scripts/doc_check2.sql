\timing on
   BEGIN ISOLATION LEVEL REPEATABLE READ;
   SET LOCAL enable_seqscan = off;
   SET LOCAL enable_bitmapscan = off;
   SELECT count(*) AS index_count FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message)
                            @@@ to_ftsquery('english', 'vacuum') OFFSET 0) s;
   SELECT count(*) AS false_rows FROM (SELECT 1 FROM ag WHERE to_ftsdoc('english', message)
                            @@@ to_ftsquery('english', 'vacuum')
       AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', 'vacuum'))
       OFFSET 0) s;
   SET LOCAL enable_seqscan = on;
   SELECT count(*) AS heap_count FROM ag WHERE fts_match(to_ftsdoc('english', message),
                                          to_ftsquery('english', 'vacuum'));
   COMMIT;
   