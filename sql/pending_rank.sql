-- pending_rank (1.13.0): a ranked scan includes documents still in the pending
-- write buffer, scored exactly as they will be once flushed.
--
-- Until 1.13.0 the ranked scan skipped pending documents (documented: they
-- were found by @@@ and counted, but ranked only after the next flush).  PR #12
-- ranked them through a heap pass over the whole match set whenever anything
-- was pending; 1.13.0 keeps the segment WAND top-k and merges the pending
-- matches into it, scored with the cursors' formula, and counts pending
-- documents in each term's df (the metapage N already counts them), so a term
-- only pending documents hold ranks too.
--
-- Oracle: every query's top-30 ids AND distances before the flush equal the
-- same query's after fts_merge() folds the pending list into a segment.
SET client_min_messages = warning;
CREATE TABLE pr (id int, d ftsdoc) WITH (autovacuum_enabled = off);
INSERT INTO pr SELECT g, to_ftsdoc('simple', 'w' || (g % 7) || ' ' || repeat('apple ', 1 + g % 5)
                                   || repeat('pad ', g % 11)) FROM generate_series(1, 3000) g;
CREATE INDEX pr_fts ON pr USING fts (d) WITH (positions = on);
VACUUM ANALYZE pr;
-- pending: strong and weak apple documents; zebra is held ONLY by pending ones
INSERT INTO pr SELECT 10000 + g, to_ftsdoc('simple', repeat('apple ', 1 + g % 9)
                      || CASE WHEN g % 3 = 0 THEN 'zebra ' ELSE '' END || repeat('pad ', g % 4))
FROM generate_series(1, 40) g;
CREATE TABLE prq (q text);
INSERT INTO prq VALUES ('apple'), ('apple & w3'), ('apple | zebra'), ('zebra'),
                       ('"apple apple"'), ('apple & !w2'), ('apple | w1 | w2 | w3');
CREATE FUNCTION pr_top(OUT q text, OUT ids int[], OUT dists numeric[]) RETURNS SETOF record
LANGUAGE sql AS $$
  SELECT q.q, array_agg(s.id ORDER BY s.rn), array_agg(round(s.dist::numeric, 12) ORDER BY s.rn)
  FROM prq q, LATERAL (SELECT id, d <=> q.q::ftsquery AS dist, row_number() OVER () AS rn
                       FROM (SELECT id, d FROM pr WHERE d @@@ q.q::ftsquery
                             ORDER BY d <=> q.q::ftsquery LIMIT 30) x) s
  GROUP BY q.q $$;
SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE TEMP TABLE pr_before AS SELECT * FROM pr_top();
SELECT fts_merge('pr_fts') AS merged;
CREATE TEMP TABLE pr_after AS SELECT * FROM pr_top();
SELECT b.q, b.ids = a.ids AS same_ids, b.dists = a.dists AS same_dists,
       cardinality(b.ids) AS n, (SELECT count(*) FROM unnest(b.ids) i WHERE i > 10000) AS pending_in_top
FROM pr_before b JOIN pr_after a USING (q) ORDER BY 1;
-- fts_search agrees with the ordering scan while rows are pending
INSERT INTO pr VALUES (20000, to_ftsdoc('simple', 'zebra zebra zebra apple'));
SELECT (SELECT array_agg(d.id ORDER BY r.score DESC, r.ctid) FROM fts_search('pr_fts', 'zebra'::ftsquery, 5) r
        JOIN pr d ON d.ctid = r.ctid)
     = (SELECT array_agg(id) FROM (SELECT id FROM pr WHERE d @@@ 'zebra'::ftsquery
                                   ORDER BY d <=> 'zebra'::ftsquery LIMIT 5) s) AS srf_eq_scan,
       (SELECT id FROM pr WHERE d @@@ 'zebra'::ftsquery ORDER BY d <=> 'zebra'::ftsquery LIMIT 1) AS best;
RESET enable_seqscan; RESET enable_bitmapscan;
DROP FUNCTION pr_top();
DROP TABLE pr, prq;
