-- reader: ranked top-10 / top-1000 over pending-heavy terms; count queries with a repeated row
SET ds.n = :'n';
SET enable_seqscan = off; SET enable_bitmapscan = off;
DO $$ DECLARE d10 int := 0; d1k int := 0; n int; nd int; BEGIN
  FOR i IN 1..current_setting('ds.n')::int LOOP
    SELECT count(*), count(DISTINCT id) INTO n, nd FROM (SELECT id FROM ds WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery
       ORDER BY to_ftsdoc('simple', body) <=> 'fresh'::ftsquery LIMIT 10) s;
    IF n <> nd THEN d10 := d10 + 1; END IF;
    SELECT count(*), count(DISTINCT id) INTO n, nd FROM (SELECT id FROM ds WHERE to_ftsdoc('simple', body) @@@ 'fresh & apple'::ftsquery
       ORDER BY to_ftsdoc('simple', body) <=> 'fresh & apple'::ftsquery LIMIT 1000) s;
    IF n <> nd THEN d1k := d1k + 1; END IF;
  END LOOP;
  RAISE NOTICE 'READER queries=% dup_top10=% dup_top1000=%', current_setting('ds.n'), d10, d1k;
END $$;
