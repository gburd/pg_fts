\timing on
   SET enable_seqscan = off;
   SET enable_bitmapscan = off;
   SELECT t.q, (SELECT count(*) FROM (
            SELECT 1 FROM ag
             WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', t.q)
               AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english', t.q))
            OFFSET 0) s) AS false_rows
   FROM unnest(ARRAY['vacuum', 'visibility & map', 'freeze', 'fix']) AS t(q);
   RESET enable_bitmapscan;
   RESET enable_seqscan;
   