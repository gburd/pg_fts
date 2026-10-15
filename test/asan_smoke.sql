-- test/asan_smoke.sql: a small, fast exercise of pg_fts's in-process C paths,
-- for the AddressSanitizer CI job (sanitizers).  The full regression suite is
-- impractical under ASan's ~15x slowdown -- a few tests load large synthetic
-- corpora and run delete/vacuum loops that take many minutes each.  This drives
-- every memory-critical path on small data: build, each query type, the pending
-- flush, bulkdelete + vacuum tail-truncation, segment merge, both doclen modes.
-- It asserts correctness so a wrong answer fails the run too; ASan asserts no
-- memory error on top.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pg_fts;

-- two indexes, sidecar on and off, so both bulkdelete docid paths run
CREATE TABLE a (id int PRIMARY KEY, body text);
INSERT INTO a SELECT g,
  'alpha w' || (g % 60) || ' beta' || (CASE WHEN g % 3 = 0 THEN ' gamma' ELSE '' END)
    || ' united states of ' || (CASE WHEN g % 7 = 0 THEN 'america' ELSE 'europe' END)
  FROM generate_series(1, 4000) g;
CREATE INDEX a_on  ON a USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=on, positions=on);
CREATE INDEX a_off ON a USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=off, positions=on);
VACUUM (FREEZE, ANALYZE) a;
SET enable_seqscan = off;

-- every query type, index-driven, with a correctness anchor from a seq scan
SELECT count(*) = (SELECT count(*) FROM a WHERE body ~ '\malpha\M')        AS term_ok
  FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery;
SELECT count(*) = (SELECT count(*) FROM a WHERE body ~ '\mbeta\M' AND body ~ '\mgamma\M') AS and_ok
  FROM a WHERE to_ftsdoc('simple', body) @@@ 'beta & gamma'::ftsquery;
SELECT count(*) > 0 AS or_ok     FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha | zzz'::ftsquery;
SELECT count(*) > 0 AS not_ok    FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha & !gamma'::ftsquery;
SELECT count(*) > 0 AS phrase_ok FROM a WHERE to_ftsdoc('simple', body) @@@ '"united states"'::ftsquery;
SELECT count(*) > 0 AS near_ok   FROM a WHERE to_ftsdoc('simple', body) @@@ 'united <2> states'::ftsquery;
SELECT count(*) > 0 AS prefix_ok FROM a WHERE to_ftsdoc('simple', body) @@@ 'alph:*'::ftsquery;
SELECT count(*) > 0 AS fuzzy_ok  FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha:1'::ftsquery;

-- ranked top-k (best-first + MaxScore paths)
SELECT count(*) = 10 AS rank_ok
  FROM (SELECT id FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery
        ORDER BY to_ftsdoc('simple', body) <=> 'alpha'::ftsquery LIMIT 10) s;

-- index-only exact count
SELECT fts_count('a_on', 'alpha'::ftsquery) = (SELECT count(*) FROM a WHERE body ~ '\malpha\M') AS count_ok;

-- pending flush on insert (I12 path): insert past the threshold, then query
SET pg_fts.pending_flush_threshold = 500;
INSERT INTO a SELECT g, 'alpha delta' FROM generate_series(100001, 101200) g;
SELECT count(*) > 0 AS pending_ok FROM a WHERE to_ftsdoc('simple', body) @@@ 'delta'::ftsquery;

-- bulkdelete + vacuum tail truncation + merge, both sidecar modes
DELETE FROM a WHERE id % 4 = 0;
VACUUM (INDEX_CLEANUP ON) a;
SELECT fts_merge('a_on') IS NOT NULL AND fts_merge('a_off') IS NOT NULL AS merge_ok;
SELECT count(*) = (SELECT count(*) FROM a WHERE body ~ '\malpha\M') AS after_vacuum_ok
  FROM a WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery;

RESET enable_seqscan;
RESET pg_fts.pending_flush_threshold;
DROP TABLE a;
