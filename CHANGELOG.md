# Changelog

All notable changes to pg_fts are documented here.

## 0.2.0

**Breaking:** the index access method was renamed **`bm25` → `fts`**
(`CREATE INDEX ... USING fts (to_ftsdoc('english', body))`).  This lets pg_fts
coexist in the same database as Timescale pg_textsearch (whose AM is named
`bm25`), so a pg_textsearch workload can be migrated one index at a time rather
than in a single hard cutover.  Existing `USING bm25` indexes must be recreated
as `USING fts`.  The BM25 scoring functions (`fts_bm25`, `fts_bm25f`,
`fts_bm25_opts`) are unchanged — BM25 is the ranking algorithm, `fts` is the
access method.

- On-disk format version check: opening an index whose stored format version
  does not match the loaded shared library now raises a clear error
  (`... has pg_fts on-disk format version N, but this build expects M`) with a
  `REINDEX` hint, instead of silently misreading the index.
- New `doc/MIGRATING_FROM_PG_TEXTSEARCH.md`: query/DDL rewrite table, the
  multi-column → concatenated-`to_ftsdoc` pattern, and index build sizing
  (`CREATE INDEX` bounds build memory to `maintenance_work_mem`).

## 0.1.0 — initial public release

First public release.  The extension was developed as an internal, qualified
feature series (each stage clean under `--enable-cassert`, regression-green)
that reached internal version 1.20 before being squashed to a single `0.1.0`
install script for release.  Versioning starts at 0.1.0 to signal that the
on-disk format and ranked-query performance will iterate before 1.0.

Included in 0.1.0:

- `ftsdoc` / `ftsquery` types, the `@@@` match operator, and the `<=>`
  relevance-ordering operator (`ORDER BY d <=> q LIMIT k` plans as an index
  scan, no Sort).
- The `bm25` inverted-index access method: WAL-logged via GenericXLog
  (crash-safe, physical-replication safe), MVCC-correct (per-segment
  tombstones), segmented (Lucene/Tantivy-style) on-disk format with a
  size-tiered background merge, block-max WAND / MaxScore top-k with lazy
  per-column decode.
- Okapi BM25 scoring with the lucene / robertson / atire / bm25+ / bm25l
  variants; BM25F multi-field weighting; index-maintained corpus statistics
  (N, avgdl, per-term df) so ranking needs no heap recheck.
- A rich query language over one operator: boolean, phrase `"a b c"`, NEAR,
  prefix `term*`, fuzzy `term~k` (Levenshtein DFA), and regex `/re/`, with a
  trigram pre-filter for fuzzy/regex.
- `fts_highlight()` / `fts_snippet()`; `tsquery_to_ftsquery()` migration helper
  and cast.
- Incremental maintenance (INSERT appends to a pending list, no REINDEX);
  `fts_merge()` and `fts_vacuum()` (compact + truncate) for on-demand
  maintenance.
- `fts_count()` and a transparent `count(*) ... WHERE @@@` CustomScan pushdown
  for MVCC-correct bulk counts from the index — a capability the specialist
  BM25 extensions do not expose.
- Parallel index build/merge; standalone PGXS build plus Nix flake and a
  Windows/MSVC meson recipe; supported on PostgreSQL 17, 18, and 19/devel.

Known performance position (see `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md` and
`HANDOFF.md`): pg_fts is far faster than the built-in tsvector/GIN + `ts_rank`
stack on ranked retrieval (up to ~40×), but trails the specialist BM25
extensions (VectorChord-bm25, Timescale pg_textsearch) on raw ranked latency and
index size, because it stores positional postings for phrase/NEAR.  Closing that
gap is a posting-codec rewrite tracked in `ROADMAP.md`; 0.1.0 ships on its
distinguishing strengths — query-language breadth, index-native COUNT, and
MVCC/crash correctness — and will iterate on ranked performance.
