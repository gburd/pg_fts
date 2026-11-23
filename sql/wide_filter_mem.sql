-- wide_filter_mem: a boolean @@@ filter that matches a large set must not
-- allocate a scratch buffer proportional to the match-set size.  Through
-- 1.18.0, bm25_filter_tombstoned_seg sized a uint64 docid buffer to the whole
-- segment match set; a wide filter over a large corpus (tens of millions of
-- rows) overran MaxAllocSize and raised "invalid memory alloc request size",
-- and under concurrency the full-set collect buffers exhausted container
-- memory.  The fix chunks the tombstone membership sweep (bounded scratch) and
-- routes the match/union/docid arrays through the huge-alloc path the result
-- array already used.  This test cannot build tens of millions of rows, so it
-- guards the behaviour the fix must preserve: the chunked tombstone sweep,
-- which now runs in 256-row batches, must compact a match set that spans many
-- batches and has tombstones scattered across batch boundaries to exactly the
-- live rows -- a wrong `j` carry across batches would drop or duplicate rows.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;

CREATE TABLE wf (id bigint, d ftsdoc) WITH (fillfactor = 100, autovacuum_enabled = off);
-- 8000 rows, every one contains 'common' (match set = 8000, ~31 batches of 256)
INSERT INTO wf SELECT g, to_ftsdoc('simple', 'common w' || (g % 211))
  FROM generate_series(1, 8000) g;
CREATE INDEX wf_fts ON wf USING fts (d);
VACUUM ANALYZE wf;

-- Delete a set scattered across the whole id range (so tombstones fall on many
-- 256-row batch boundaries), then VACUUM to turn them into per-segment
-- tombstones the collect path must filter.
DELETE FROM wf WHERE id % 7 = 0;
VACUUM wf;

-- The @@@ filter count (collect path, chunked tombstone sweep) must equal the
-- heap truth (seq scan) and the fts_count pushdown.  8000 - floor(8000/7) live.
SELECT (SELECT count(*) FROM wf WHERE fts_match(d, 'common'::ftsquery)) AS truth,
       (SELECT count(*) FROM wf WHERE d @@@ 'common'::ftsquery) AS filter_count,
       fts_count('wf_fts', 'common'::ftsquery) AS fts_count;

-- A wide disjunction filter (the shape Zishuo's failing queries took) over the
-- same large live set: count must still match the heap, and the bitmap must
-- carry no deleted row.
SET enable_seqscan = off;
SELECT count(*) AS bitmap_rows,
       count(*) FILTER (WHERE id % 7 = 0) AS deleted_leaked
FROM (SELECT id FROM wf
      WHERE d @@@ to_ftsquery('simple', 'common | w1 | w2 | w3 | w4 | w5') OFFSET 0) s;
RESET enable_seqscan;

DROP TABLE wf;
