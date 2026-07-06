# Changelog

All notable changes to pg_fts are documented here.  The extension version
(the `default_version` in `pg_fts.control`) advances one step per feature; the
public release series tracks those.

## Unreleased / toward 1.0 public release

- Standalone (out-of-tree) build via PGXS; no PostgreSQL source tree required.
- Supported on PostgreSQL 17, 18, and current devel.

## 1.20

- `fts_vacuum(regclass)`: reclaim physical index bloat by compacting to one
  segment (reusing the lowest free blocks) and truncating the free tail back to
  the OS — shrinks an index grown larger than its live contents without a
  REINDEX.  Runs automatically during `VACUUM` when the index is substantially
  bloated.
- Transparent COUNT pushdown: a plain `count(*) ... WHERE col @@@ q` is answered
  from the index by a `Custom Scan (FtsCount)` (visibility-map bulk count),
  ~3× faster than the bitmap heap scan, with no need to call `fts_count()`.
- Faster posting decode: word-oriented FOR unpack (~5.7× the per-value cost),
  cutting common-term `fts_count` ~3×.
- Parallel index build/merge: concurrent segment writes (per-page relation
  extension lock), so `CREATE INDEX` and `fts_merge` parallelize the scan and
  intermediate merges.

## 1.0 – 1.19

The reviewable feature series: `ftsdoc`/`ftsquery` types and the `@@@`/`<=>`
operators; the `bm25` access method (GenericXLog crash-safe, MVCC-correct);
Okapi BM25 with the lucene/robertson/atire/bm25+/bm25l variants; highlight and
snippet; `tsquery` migration; index-maintained corpus statistics; incremental
maintenance via a pending list; phrase / prefix / fuzzy / regex queries;
external-content (expression) indexing; block-max WAND / MaxScore top-k with
lazy per-column decode; the segmented (Lucene/Tantivy-style) on-disk format with
size-tiered background merge; per-segment tombstones for DELETE/UPDATE; and
`fts_count()` for MVCC-correct bulk counts.  See README.md for the per-version
list.
