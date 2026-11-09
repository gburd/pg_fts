# pg_fts 1.15.1: ranked top-k 100-500x slower once VACUUM tombstones many rows in a large segment

Found 2026-11-02 on a production index of a public mail archive (pg.ddx.io). Reproduced
from scratch on synthetic data; script below. Workaround: REINDEX. No patch from us.

The working tree of pg_fts already has an Unreleased CHANGELOG entry ("Ranked top-k became
60-300x slower after deletes scattered over a large heap, until a REINDEX") that fixes
this. This report adds a reproduction that needs no production data, the stack sample, and
the conditions under which `fts_vacuum` / `fts_merge` do or do not clear it. Please treat it
as confirmation and test material for that fix.

## Environment
- PostgreSQL 18.6, pg_fts 1.15.1, x86_64 Linux. GUCs at their defaults (`pg_fts.bestfirst`
  on, `pg_fts.shared_doclen` on, `pg_fts.doclen_cache_mb` 64).
- Index: `USING fts (to_ftsdoc('english', head || ' ' || own)) WITH (doclen_sidecar = off)`.

## What happened in production
- 1.88 M rows (avgdl about 150), index about 1.1 GB, one segment after an `fts_vacuum`.
- A batch job moved 23,313 rows: it deleted each one and inserted the same text under a new
  key, in 24 transactions, rows spread over the whole heap. Then `fts_vacuum`, then
  autovacuum of the heap, which tombstoned the 23,313 deleted rows in the packed segment.
- After that, every ranked top-k on the index was slow. All buffers were hit, with no waits
  and no locks:
  - `fts_search(idx, to_ftsquery('english','remove'), 200)` (df 113,723): **5,735 ms**.
    The same call 3 times in one session: 11.6 s, 5.7 s, then 2.2 s twice for 'vacuum'.
    So it is not a per-session warm-up.
  - A 4-term OR top-200 through the executor: 2.8-6.0 s.
  - An unranked count(*) of 'vacuum': 312 ms (it would normally be about 60 ms).
- At the same time, two other fts indexes on the same server, with no bulk deletes, were
  fine: 15 ms and 446 ms for comparable calls.
- `REINDEX INDEX CONCURRENTLY` (built in 198 s, 1 segment) restored it at once:
  `fts_search` 'remove' top-200 went 5,735 ms -> 6 ms; 'vacuum' top-200 3.6 ms.

## Reproduction (scratch, synthetic data)
Script: the SQL file at the end of this report. Run it as
`psql -v nrows=1880000 -v nmoves=23313 -f repro.sql`. It takes about 15 min on a 16-core box.
- Each row is 40-160 Zipf-distributed words from a 40,000-word vocabulary.
- 'remove' appears in 6% of rows and 'vacuum' in 3%.
- Autovacuum is off on the table, so each VACUUM happens where the script puts it.
- Each step times a warm `fts_search(..., 200)`.

| step | segments | 'remove' top-200 | 'vacuum' top-200 | 'remove', bestfirst = off |
|---|---:|---:|---:|---:|
| A fresh build, fts_vacuum | 1 | 12 ms | 6 ms | 2 ms |
| B 23,313 moves (no pack, no VACUUM) | 2 | 19 ms | 27 ms | 5 ms |
| C then fts_vacuum (dead heap rows still present) | 1 | 9 ms | 13 ms | 2 ms |
| **D then VACUUM** (the production order) | 1 | **3,532 ms** | **1,514 ms** | **3,315 ms** |
| E then fts_vacuum (returns f) | 1 | 3,484 ms | 1,451 ms | 3,298 ms |
| F then fts_merge (returns f) | 1 | 3,410 ms | 1,537 ms | 4,392 ms |
| G REINDEX | 1 | 14 ms | 7 ms | 3 ms |
| H moves, VACUUM, then fts_vacuum | 1 | 10 ms | 5 ms | 2 ms |
| I moves, VACUUM, no pack | 3 | 3,610 ms | 1,592 ms | 10 ms |

The same at 400 k rows and 5,000 moves: step D was 79 ms against 4 ms fresh. So the cost
grows with the tombstone count, not with the row count alone.

Follow-ups at full size:

| run | 'remove' top-200 |
|---|---:|
| REINDEX, 23,313 moves, VACUUM, no pack (3 segments) | 5,877 ms |
| then fts_vacuum (returns t: it merges the 3 segments into 1) | 18.5 ms |
| REINDEX, 2,000 moves, VACUUM | 58 ms |
| REINDEX, 500 moves, VACUUM | 64 ms |

What the table shows:
1. **The trigger is VACUUM tombstoning many deleted rows inside a large segment.** The order
   of the pack does not matter. Packing after the VACUUM clears it (H) only because that
   pack merges segments and so rewrites the tombstoned rows away.
2. **Once the index is one packed segment, `fts_vacuum` and `fts_merge` cannot clear it.**
   Both return false and rewrite nothing (E, F), so the tombstones stay until a REINDEX.
   From an operator's side, packing looks like the fix but is a no-op here.
3. **The best-first path is the slower one.** With `pg_fts.bestfirst = off` the cost stays
   (D: 3.3 s) when the tombstones are in the one segment. It drops to 10 ms when they sit in
   a smaller segment (I).

## Where the time goes
25 stack samples (`eu-stack`, 0.4 s apart) of a backend running the slow step D query; all 25
had the same top frames:

```
__sm_get_chunk_offset
__pg_bm25_sm_contains
fts_search_bestfirst_n
fts_search_wand
bm25_topk_candidates_range
bm25_topk_visible
fts_search
```

`wand_cur_own_tombstoned()` passes `c->tombcursor`, but `fts_search_bestfirst_n` resets that
cursor to `SM_CURSOR_INIT` for every block it visits ("blocks are visited out of docid
order"). Each visited 128-posting block then starts `__sm_get_chunk_offset` at chunk 0 and
walks a chunk list that, with tombstones scattered over the heap, holds about one chunk per
tombstone. That is O(blocks visited x tombstone chunks). The Unreleased entry also names a
second cause: the cursor fast path only resumes when `idx >= cur->start_idx`, so a lookup in
the gap before the cached chunk walks from the head. We did not separate those two costs.

## Suggestions (for the author to judge)
- The checkpointed seek in the Unreleased entry fits this repro. Steps D and I make a
  regression test that needs no external data: the table should stay within a small
  factor of step A at every step.
- `fts_vacuum` on a single packed segment that carries tombstones could rewrite the
  segment, or report that it did not. Today it returns false, and an operator cannot tell
  that the tombstones are still costing every ranked scan.
- A way to see tombstone counts per segment from SQL (`fts_index_stats` has none) would have
  made this a one-query diagnosis.

## Workaround we use
After any bulk DELETE on an fts-indexed table: `REINDEX INDEX CONCURRENTLY` (we run it as a
build, verify, rename and drop). We also time one ranked top-200 of a common term
every 30 minutes and alert past 500 ms.

## Repro script
```sql
-- psql -v nrows=1880000 -v nmoves=23313 -f repro.sql   (scratch database only)
\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS own;
CREATE TABLE own (num bigint PRIMARY KEY, head text, own text) WITH (autovacuum_enabled = off);
SELECT setseed(0.42);
INSERT INTO own
SELECT g, 'subject ' || g,
       (SELECT string_agg('w' || floor(power(random(), 3) * 40000)::int, ' ')
          FROM generate_series(1, 40 + (g % 7) * 20) s WHERE g > 0)
       || CASE WHEN random() < 0.06 THEN ' remove' ELSE '' END
       || CASE WHEN random() < 0.03 THEN ' vacuum' ELSE '' END
  FROM generate_series(1, :nrows) g;
CREATE INDEX idx_own_fts ON own USING fts (to_ftsdoc('english'::regconfig, ((head || ' '::text) || own))) WITH (doclen_sidecar = off);
VACUUM ANALYZE own;
SELECT fts_vacuum('idx_own_fts'::regclass) \gset
CREATE OR REPLACE FUNCTION probe(label text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; a numeric; b numeric; c numeric;
BEGIN
  PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'remov'::ftsquery, 200);
  t0 := clock_timestamp(); PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'remov'::ftsquery, 200);
  a := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
  t0 := clock_timestamp(); PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'vacuum'::ftsquery, 200);
  b := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
  SET LOCAL pg_fts.bestfirst = off;
  t0 := clock_timestamp(); PERFORM count(*) FROM fts_search('idx_own_fts'::regclass, 'remov'::ftsquery, 200);
  c := round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
  RETURN format('%-50s segs %s  remove %s ms  vacuum %s ms  remove/bestfirst=off %s ms',
                label, fts_index_nsegments('idx_own_fts'::regclass), a, b, c);
END $$;
-- delete n scattered rows and re-insert their text under new keys, in 24 transactions
CREATE OR REPLACE PROCEDURE moves(n int) LANGUAGE plpgsql AS $$
DECLARE b int; base bigint;
BEGIN
  SELECT max(num) INTO base FROM own;
  CREATE TEMP TABLE IF NOT EXISTS mv (num bigint);
  TRUNCATE mv;
  INSERT INTO mv SELECT num FROM own ORDER BY random() LIMIT n;
  FOR b IN 0..23 LOOP
    WITH d AS (DELETE FROM own o USING (SELECT num FROM mv WHERE num % 24 = b) m
               WHERE o.num = m.num RETURNING o.num, o.head, o.own)
    INSERT INTO own SELECT base + num, head, own FROM d;
    COMMIT;
  END LOOP;
END $$;
SELECT probe('A fresh build, packed');
CALL moves(:nmoves);
SELECT probe('B moves');
SELECT fts_vacuum('idx_own_fts'::regclass) \gset
SELECT probe('C then fts_vacuum');
VACUUM own;
SELECT probe('D then VACUUM');
SELECT fts_vacuum('idx_own_fts'::regclass) AS did \gset
SELECT probe('E then fts_vacuum (returned ' || :'did' || ')');
SELECT fts_merge('idx_own_fts'::regclass) AS did \gset
SELECT probe('F then fts_merge (returned ' || :'did' || ')');
REINDEX INDEX idx_own_fts;
SELECT probe('G REINDEX');
CALL moves(:nmoves);
VACUUM own;
SELECT fts_vacuum('idx_own_fts'::regclass) \gset
SELECT probe('H moves, VACUUM, then fts_vacuum');
CALL moves(:nmoves);
VACUUM own;
SELECT probe('I moves, VACUUM, no pack');
```
