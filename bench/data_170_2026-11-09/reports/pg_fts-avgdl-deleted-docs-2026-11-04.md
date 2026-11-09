# pg_fts 1.16.0: avgdl keeps counting deleted documents until a REINDEX

Found 2026-11-04 while qualifying 1.16.0 on a copy of a production mail-archive index. Also
present in 1.15.2. Not a crash and not a wrong match set; it shifts BM25 scores. No patch from
us; reproduction below.

## What happens
`fts_index_stats(idx).avgdl` is `meta.sumdoclen / meta.ndocs`. After a DELETE + VACUUM,
`ndocs` drops (bm25_bulkdelete's "refresh corpus N" recomputes it from the segments minus
tombstones), but `sumdoclen` keeps the deleted documents' lengths. Merges carry each input
segment's `sumdoclen` whole (`bs->sumdoclen += chosen[i].sumdoclen`, with
`bs->ndocs += ndocs - ndeleted`) and the 1.16.0 `fts_vacuum` expunge keeps it too. Only a
rebuild resets it. The scan paths divide the two (`pg_fts_am_scan.c`, the `avgdl =
meta.sumdoclen / meta.ndocs` sites), so every ranked query normalises lengths against an
average that includes rows that are gone.

## Reproduction (scratch database, both 1.15.2 and 1.16.0)
```sql
CREATE EXTENSION pg_fts;
CREATE TABLE t (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
-- even ids: 10 words; odd ids: 100 words
INSERT INTO t SELECT g, (SELECT string_agg('w' || ((g * 7 + s) % 5000), ' ')
    FROM generate_series(1, CASE WHEN g % 2 = 0 THEN 10 ELSE 100 END) s)
  FROM generate_series(1, 200000) g;
CREATE INDEX t_fts ON t USING fts (to_ftsdoc('simple', body));
DELETE FROM t WHERE id % 2 = 1;   -- all the long rows
VACUUM t;
SELECT ndocs, avgdl FROM fts_index_stats('t_fts'::regclass);
SELECT fts_vacuum('t_fts'::regclass);  -- 1.16.0: t (rewrites the segment); 1.15.2: f
SELECT ndocs, avgdl FROM fts_index_stats('t_fts'::regclass);
REINDEX INDEX t_fts;
SELECT ndocs, avgdl FROM fts_index_stats('t_fts'::regclass);
```

| step | ndocs | avgdl | true average length |
|---|---:|---:|---:|
| built | 200,000 | 55.000 | 55.000 |
| long rows deleted, VACUUM | 100,000 | **110.000** | 10.000 |
| then fts_vacuum (1.16.0 returns t) | 100,000 | **110.000** | 10.000 |
| then fts_merge | 100,000 | **110.000** | 10.000 |
| REINDEX | 100,000 | 10.000 | 10.000 |

110 = (all 200,000 rows' lengths) / (the 100,000 left): the deleted half still counts in the
numerator.

## On real data
On the 1.88M-row copy, after three rounds of 23,313 delete+reinsert moves with VACUUM and
fts_vacuum, avgdl read 144.43 against 139.39 after REINDEX of the same rows (+3.6%). For a
3-term OR top-200: the 1.16.0 expunge left avgdl at 144.43 and changed the scores only through
df (tombstoned documents leave it: 109,398 -> 108,042 for 'remove'), with the same ids. The
REINDEX that followed, the same rows and the same df, changed scores and ids: that difference
is avgdl alone.

## Suggestion (for the author to judge)
Subtract a document's length from the corpus (and segment) `sumdoclen` when it is
tombstoned. bulkdelete already visits each newly dead docid and can read its length from the
inline column or the sidecar. The other option is to recompute sumdoclen from the surviving
postings when a merge or the expunge drops tombstoned documents. The 1.16.0 expunge is a
natural point to do that, since it rewrites every surviving document.

## What we do meanwhile
After a bulk delete we rebuild with REINDEX CONCURRENTLY, which also restores avgdl.
