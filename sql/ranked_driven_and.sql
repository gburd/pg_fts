-- ranked_driven_and (1.15.0, ROADMAP I19a/I19b, Codeberg #6): a ranked pure-boolean
-- AND whose cheapest required operand is small is driven from that operand's
-- postings.  Through 1.14.3 `rare & (a | b)` took the BoolGate walk over a's and b's
-- cursors: with few matches the threshold stayed low, a gate-rejected pivot never
-- raised it, so every posting of the OR group was visited.  Separately, the collect
-- path (`zzzq & (a | b:*)`, a prefix makes it non-pure-boolean) built every operand's
-- TID set before the AND met the empty required term; it now checks a plain required
-- term's segment df first.  Oracle: a seq scan + fts_bm25 with the index's
-- statistics, and the same query through the docid-order walk (pg_fts.bestfirst = off).
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE rd (id int, d ftsdoc) WITH (autovacuum_enabled = off);
-- apple in id % 4 = 0, banana in id % 4 = 1, cherry in id % 3 = 0; rare in 7 rows,
-- mid (driver of the OR form) in id % 97 = 0; at most 7 tokens a row (exact doclen)
INSERT INTO rd SELECT g, to_ftsdoc('simple', concat_ws(' ', 'w' || (g::bigint * 7919 % 300),
       CASE WHEN g % 4 = 0 THEN 'apple' END, CASE WHEN g % 4 = 1 THEN 'banana' END,
       CASE WHEN g % 3 = 0 THEN 'cherry' END,
       CASE WHEN g IN (12, 13, 400, 401, 9000, 15001, 19999) THEN 'rare' END,
       CASE WHEN g % 97 = 0 THEN 'mid' END, CASE WHEN g % 89 = 0 THEN 'odd' END))
  FROM generate_series(1, 20000) g;
CREATE INDEX rd_fts ON rd USING fts (d);
VACUUM ANALYZE rd;

CREATE FUNCTION pg_temp.ranked(qt text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(id || ':' || round(sc::numeric, 9), ',' ORDER BY sc DESC, id), '')
    FROM (SELECT p.id, r.score AS sc FROM fts_search('rd_fts', qt::ftsquery, 100000) r
            JOIN rd p ON p.ctid = r.ctid) s $$;
CREATE FUNCTION pg_temp.top10(qt text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(id || ':' || round(sc::numeric, 9), ',' ORDER BY sc DESC, id), '')
    FROM (SELECT p.id, r.score AS sc FROM fts_search('rd_fts', qt::ftsquery, 10) r
            JOIN rd p ON p.ctid = r.ctid) s $$;
CREATE FUNCTION pg_temp.oracle(qt text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off;
  WITH st AS MATERIALIZED (SELECT s.ndocs, s.avgdl, fts_index_df('rd_fts', qt::ftsquery) AS df
                             FROM fts_index_stats('rd_fts') s)
  SELECT coalesce(string_agg(id || ':' || round(sc::numeric, 9), ',' ORDER BY sc DESC, id), '') INTO r
    FROM (SELECT id, fts_bm25(d, qt::ftsquery, st.ndocs, st.avgdl, st.df) AS sc
            FROM rd, st WHERE d @@@ qt::ftsquery) x;
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.walk10(qt text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  SET LOCAL pg_fts.bestfirst = off;
  r := pg_temp.top10(qt);
  RETURN r;
END $$;
CREATE TABLE rq (q text);
INSERT INTO rq VALUES
  ('rare & (apple | banana)'), ('(apple | banana) & rare'), ('rare & (apple | banana | cherry)'),
  ('rare & (apple | banana) & !cherry'), ('mid & (apple | banana)'), ('(mid | rare) & (apple | cherry)'),
  ('rare & apple & (banana | cherry)'), ('(rare & apple) | (rare & banana)'), ('!rare & mid & (apple | odd)'),
  ('rare & !(apple | banana)'), ('odd & (apple | banana | cherry | w7 | w8)'), ('apple & (banana | cherry)'),
  ('zzzq & (apple | ban:*)'), ('rare & (apple | ban:*)'), ('mid & (app:* | banana)'), ('zzzq & app:* & cherry');
SELECT q, length(o) > 0 AS nonempty, pg_temp.ranked(q) = o AS full_same_as_oracle,
       pg_temp.top10(q) = pg_temp.walk10(q) AS top10_same_as_walk
  FROM (SELECT q, pg_temp.oracle(q) AS o FROM rq) s ORDER BY q;

-- the driven path visits the driver's postings, not the OR group's: index buffers
-- for the ranked top-10.  Measured on this table (PG 17.10): `rare & (apple | banana)`
-- 111 on 1.14.3 (more than `apple | banana`'s 93), 56 here.  `zzzq & (apple | ban:*)`
-- 26 -> 17, and `zzzq & (apple | banana | cherry | ban:*)` 42 -> 23: the collect path
-- no longer builds the OR group, and costs about what `zzzq & ban:*` (14) does.
SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE FUNCTION pg_temp.hits(qt text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE l text; h int := 0;
BEGIN
  FOR l IN EXECUTE format('EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
      SELECT id FROM rd WHERE d @@@ %L::ftsquery ORDER BY d <=> %L::ftsquery LIMIT 10', qt, qt)
  LOOP
    IF l ~ '^\s*Buffers: shared hit=' AND h = 0 THEN h := substring(l from 'hit=(\d+)')::int; END IF;
  END LOOP;
  RETURN h;
END $$;
SELECT pg_temp.hits('rare & (apple | banana)') < pg_temp.hits('apple | banana') * 3 / 4 AS driven_reads_less;
SELECT pg_temp.hits('zzzq & (apple | banana | cherry | ban:*)') < pg_temp.hits('zzzq & ban:*') * 2 AS collect_skips_or_group;
RESET enable_seqscan; RESET enable_bitmapscan;

-- multi-segment + pending: a second segment and pending rows hold the driver too
SET pg_fts.pending_flush_threshold = 20;   -- inline flushes: new segments
INSERT INTO rd SELECT g, to_ftsdoc('simple', 'rare apple w' || (g % 300)) FROM generate_series(20001, 20040) g;
SELECT fts_index_nsegments('rd_fts') > 1 AS several_segments;
SET pg_fts.pending_flush_threshold = 0;
INSERT INTO rd SELECT g, to_ftsdoc('simple', 'rare banana cherry') FROM generate_series(20041, 20050) g;
RESET pg_fts.pending_flush_threshold;
SELECT q, length(o) > 0 AS nonempty, pg_temp.ranked(q) = o AS full_same_as_oracle,
       pg_temp.top10(q) = pg_temp.walk10(q) AS top10_same_as_walk
  FROM (SELECT q, pg_temp.oracle(q) AS o FROM rq WHERE q ~ 'rare') s ORDER BY q;
DROP TABLE rd, rq;
