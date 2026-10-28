-- inserter: single-row commits, inline flush every 20 pending docs
SET ds.n = :'n';
SET pg_fts.pending_flush_threshold = 20;
DO $$ BEGIN
  FOR i IN 1..current_setting('ds.n')::int LOOP
    INSERT INTO ds (body) VALUES ('fresh apple w' || (i % 50));
    COMMIT;
  END LOOP;
END $$;
