# Migrating from pg_textsearch to pg_fts

This guide is for users moving a Timescale **pg_textsearch** workload to
**pg_fts**. It covers the query/DDL rewrite, the multi-column pattern, index
build sizing, and how to migrate gradually (both extensions can coexist).

## They can coexist — migrate index by index

pg_fts's access method is named **`fts`**, and pg_textsearch's is **`bm25`**.
Because the access-method names differ, **both extensions can be installed in
the same database at the same time.** You do not need an atomic cutover: install
pg_fts alongside pg_textsearch, migrate one index / query path at a time, verify,
and drop the pg_textsearch index when you are done.

```sql
CREATE EXTENSION pg_fts;      -- alongside an existing pg_textsearch install
```

> pg_fts is **not** a transparent drop-in: it uses different types
> (`ftsdoc`/`ftsquery`), a different match operator (`@@@`) and ordering
> operator (`<=>`), and requires the query to name the text-search config. The
> rewrite is mechanical (table below) but every call site changes.

## Query / DDL rewrite

pg_fts analyzes text into an `ftsdoc` and parses queries into an `ftsquery`; the
text-search config (e.g. `'english'`) is named explicitly on both sides so the
document and the query normalize (stem/stopword) identically.

| Task | pg_textsearch | pg_fts |
|------|---------------|--------|
| Create index | `CREATE INDEX ON t USING bm25(body) WITH (text_config='english')` | `CREATE INDEX ON t USING fts (to_ftsdoc('english', body))` |
| Ranked top-k | `ORDER BY body <@> 'q' LIMIT k` | `ORDER BY to_ftsdoc('english',body) <=> to_ftsquery('english','q') LIMIT k` |
| Ranked, explicit index | `ORDER BY body <@> to_bm25query('q','idx') LIMIT k` | (same as above — pg_fts resolves the index from the ordering operator) |
| Boolean match / filter | *(not supported by pg_textsearch)* | `WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','q')` |
| Count matches | *(not supported)* | `SELECT count(*) ... WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','q')` (index-answered) or `fts_count('idx', to_ftsquery('english','q'))` |
| Phrase / prefix / fuzzy / regex | *(not supported)* | `to_ftsquery('english', '"a b" & pre* & fuzzy~2 & /re/')` |

Notes:

- `<@>` returns a *negative* score (pg_textsearch sorts ASC on it). pg_fts's
  `<=>` is a **distance** (smaller = more relevant), so `ORDER BY ... <=> ...`
  is already correct-direction — no negation, no `DESC`.
- Because pg_fts indexes an **expression** (`to_ftsdoc('english', body)`), the
  same expression must appear in the query for the index to be used — this is
  ordinary PostgreSQL expression-index behavior, and matches pg_textsearch's own
  rule for its expression/partial indexes.
- pg_fts adds capabilities pg_textsearch does not have: a boolean match
  predicate (`@@@`), an index-native `count(*)`, and phrase / prefix / fuzzy /
  regex queries. These are the reason for the explicit `ftsdoc`/`ftsquery`
  types.
- **If you use phrase queries, read this before benchmarking pg_fts against
  pg_textsearch.** Two things will otherwise surprise you:
  1. **Phrase syntax uses double quotes.** `to_ftsquery('english', '"united
     states"')` is a phrase; single quotes give a plain conjunction
     (`'unit' & 'state'`), which matches far more rows. We published a benchmark
     number that was wrong for exactly this reason.
  2. **Add `WITH (positions = on)` at `CREATE INDEX` time.** It defaults to *off*,
     and without it a phrase cannot be verified from the index — the scan falls
     back to a conjunction plus a heap recheck of every candidate. On 2.19M
     articles a ranked phrase costs **8,385 ms** with the default and **229 ms**
     with positions on (36x); an exact phrase `count(*)` goes 7,170 ms → 132 ms.
     The cost is a larger index (1,421 MB → 2,626 MB on that corpus). See
     `bench/NOTE_PHRASE_PROFILE_2026-09-06.md`.
- **Build tuning:** raise `maintenance_work_mem` to >= 1GB for a large initial
  build. At PostgreSQL's 64MB default a 2.19M-document build leaves 8 segments
  plus a ~216 s merge and an index twice the necessary size. Do *not* raise
  `max_parallel_maintenance_workers` to speed up a merge — it makes merges 1.45x
  slower and 19% larger (`bench/RESULTS_PARALLEL_MERGE_2026-09-08.md`).

## Multi-column search

pg_fts's `fts` access method indexes a **single** `ftsdoc` (it is
`amcanmulticol = false`). To search several columns — as pg_textsearch does with
a multi-column `bm25(subject, from, body)` index — concatenate the fields into
one `to_ftsdoc(...)`:

```sql
-- multi-field, single index key (like-for-like with a concatenated bm25 index)
CREATE INDEX docs_fts ON docs
  USING fts (to_ftsdoc('english', subject || ' ' || from_ || ' ' || body));

SELECT id FROM docs
 WHERE to_ftsdoc('english', subject || ' ' || from_ || ' ' || body)
       @@@ to_ftsquery('english', 'q');
```

This is a faithful port of a concatenated-text `<@>` index and has no ranking
regression relative to it. Per-field BM25F weighting (scoring a term higher when
it appears in the subject than the body) is a separate, later step using
`fts_bm25f(ftsdoc[], ...)` and is **not** required for a like-for-like cutover.

## Index build sizing

pg_fts's `CREATE INDEX` bounds its build memory to **`maintenance_work_mem`**:
it accumulates an in-memory segment up to that budget, flushes it, and starts
fresh, so a large corpus does **not** require RAM proportional to the index
size. This is the key difference from pg_textsearch 1.2.x, whose builder could
fail on very large text columns.

Recommendations for a large body-content index:

- Set `maintenance_work_mem` to a comfortable fraction of host RAM (e.g. 1–4 GB)
  — higher makes fewer, larger segments (less post-build merge) but does not
  risk OOM, because the build flushes at the budget.
- The build is CPU-bound (single-threaded text analysis) unless parallel build
  is enabled; raise `max_parallel_maintenance_workers` to parallelize the scan.
- After a bulk build or heavy merge, run `fts_vacuum('idx')` to compact the
  index and return physical space to the OS.

## Suggested migration steps

1. `CREATE EXTENSION pg_fts;` (coexists with pg_textsearch).
2. Build the pg_fts index next to the existing pg_textsearch one
   (`USING fts (to_ftsdoc('english', ...))`).
3. Rewrite queries per the table above behind a feature flag; verify results and
   relevance against the pg_textsearch path.
4. Cut traffic over, then `DROP INDEX` the pg_textsearch index and, once no
   indexes remain, `DROP EXTENSION pg_textsearch`.

## On-disk format changes

pg_fts stamps each index with a format version and validates it on open: if a
future pg_fts shared library is loaded against an index built by an incompatible
format, it raises a clear error (`... has pg_fts on-disk format version N, but
this build expects version M`) with a `REINDEX` hint, rather than misreading the
index.
