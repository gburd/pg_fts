# pg_fts — BM25 full-text search for PostgreSQL

A PostgreSQL extension for full-text search with true **BM25/BM25F** relevance
ranking, a dedicated `fts` inverted-index access method, and a rich query
language (boolean, phrase, NEAR, prefix, fuzzy, regex).  Unlike the
`tsvector`/`tsquery` + GIN stack, the index maintains the corpus statistics
BM25 needs (document count, average length, per-term document frequency) and
stores term frequency + document length in the posting lists, so ranking is
answered from the index with no heap recheck.

## Requirements

- PostgreSQL **17 or newer** (17, 18, and current `master`/devel are supported;
  version differences are handled with compile-time guards).
- A C toolchain and the PostgreSQL server headers (`postgresql-server-dev-*`
  or a source install exposing `pg_config`).

## Build and install

```sh
make PG_CONFIG=/path/to/pg_config
sudo make install PG_CONFIG=/path/to/pg_config
```

`PG_CONFIG` defaults to whatever `pg_config` is on `PATH`.

On Windows with MSVC (where PostgreSQL is built with meson rather than PGXS)
use the meson recipe instead, pointing `pg_dir` at an MSVC-built PostgreSQL
≥ 17 (a MinGW/Strawberry PostgreSQL will not work):

```sh
meson setup build -Dpg_dir=C:/pgsql --buildtype=release
ninja -C build
ninja -C build install
```

With [Nix](https://nixos.org) (flakes) you can build and test without a local
PostgreSQL install:

```sh
nix build .#default              # build against nixpkgs PostgreSQL 17
nix flake check                  # build + regression/isolation tests, PG 17 and 18
nix develop                      # dev shell with the toolchain + pg_config
nix run .#docs                   # validate doc/pg_fts.sgml
```

## Test

```sh
# against a running server (regression + isolation; TAP needs a
# --enable-tap-tests build):
make installcheck PG_CONFIG=/path/to/pg_config
```

Standalone property-based tests (hegel-c) for the pure-C codec/automaton cores
live in [`test/hegel/`](test/hegel/README.md); they need extra deps (hegel-c,
libcbor, cmocka, the `hegel` binary) and are separate from `make installcheck`.

## Use

```sql
CREATE EXTENSION pg_fts;

CREATE TABLE docs (id bigint, body text);
-- index the analyzed document
CREATE INDEX docs_bm25 ON docs USING fts (to_ftsdoc('english', body));

-- boolean / phrase / prefix / fuzzy / regex match
SELECT id FROM docs
 WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'quick & fox');

-- BM25-ranked top-k (index-only ordering scan)
SELECT id FROM docs
 ORDER BY to_ftsdoc('english', body) <=> to_ftsquery('english', 'quick fox')
 LIMIT 10;

-- fast COUNT (transparent: a plain count(*) WHERE @@@ is pushed to the index)
SELECT count(*) FROM docs
 WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'quick');

-- maintenance
SELECT fts_merge('docs_bm25');    -- compact segments now
SELECT fts_vacuum('docs_bm25');   -- reclaim disk space (compact + truncate)
```

See `doc/pg_fts.sgml` for the full reference, `CAPABILITIES.md` for the feature
matrix, `ROADMAP.md` for the roadmap, and
`doc/MIGRATING_FROM_PG_TEXTSEARCH.md` if you are moving from Timescale
pg_textsearch.

---

pg_fts -- BM25 full-text search for PostgreSQL
==============================================

pg_fts is a contrib extension providing full-text search with BM25/BM25F
relevance ranking, a dedicated inverted-index access method, phrase/prefix/
fuzzy/regex query support, and result presentation.  It differs from the
tsvector/tsquery + GIN stack in that the index maintains the corpus statistics
(document count, average length, per-term document frequency) BM25 ranking
requires, and posting lists carry term frequency and document length, so
ranking needs no heap recheck.

The extension is developed as a qualified feature series (each stage builds
clean under --enable-cassert and passes its regression test).  The internal
series reached 1.20 before being squashed to a single 0.1.0 install script for
the first public release.

Features
--------

  * ftsdoc/ftsquery types, to_ftsdoc()/to_ftsquery(), the @@@ match operator
  * the fts index access method (bitmap scan + <=> ordering scan, GenericXLog
    crash-safe, MVCC-correct)
  * fts_bm25(): Okapi BM25 scoring, with the lucene/robertson/atire/bm25+/bm25l
    variants; fts_bm25f(): BM25F multi-field weighting
  * index-maintained corpus statistics (fts_index_stats()/fts_index_df()) so
    ranking needs no heap recheck
  * fts_highlight() and fts_snippet(); tsquery_to_ftsquery() migration + cast
  * phrase queries ("a b c") via per-term positions; prefix (term*), fuzzy
    (term~k, Levenshtein DFA), and regex (/re/) terms, with a trigram pre-filter
  * external-content indexing via an expression index on to_ftsdoc(col)
  * incremental maintenance (INSERT appends to a pending list, no REINDEX);
    background/on-demand merge (fts_merge()) and compaction (fts_vacuum())
  * block-max WAND / MaxScore top-k with lazy per-column decode; fts_search()
    index-only BM25 top-k
  * fts_count(): MVCC-correct bulk count via the index, plus a transparent
    count(*) WHERE @@@ CustomScan pushdown

Query language
--------------

  quick brown          implicit AND
  quick & brown        AND          quick | brown   OR      !slow / -slow  NOT
  (a | b) & c          grouping
  "quick brown fox"    phrase (adjacent)
  quick*               prefix
  quick~2              fuzzy, edit distance <= 2
  /^qu.*x$/            regex over each term
  title AND fox        keyword operators (AND/OR/NOT, case-insensitive)

Example
-------

  CREATE EXTENSION pg_fts;

  CREATE TABLE docs (id int, body text);
  CREATE INDEX docs_bm25 ON docs USING fts (to_ftsdoc('english', body));

  SELECT id,
         fts_bm25(to_ftsdoc('english', body), q,
                  s.ndocs, s.avgdl,
                  fts_index_df('docs_bm25', q)) AS score,
         fts_snippet(body, q) AS excerpt
  FROM docs, fts_index_stats('docs_bm25') s,
       to_ftsquery('postgres & "query planner" & index*') q
  WHERE to_ftsdoc('english', body) @@@ q
  ORDER BY score DESC
  LIMIT 10;

Performance
-----------

bench/ contains reproducible benchmarks on EC2 (build time, index size, and
per-query-type latency at 2M+ docs).  See bench/RESULTS_*.md for the full
analysis.  The honest summary:

  * vs the built-in tsvector/GIN + ts_rank stack, pg_fts is far faster on ranked
    retrieval (up to ~40x on common-term top-k, because ts_rank must fetch and
    sort every match) — see bench/RESULTS_WIKIPEDIA_2M.md.
  * vs the specialist BM25 extensions (VectorChord-bm25, Timescale
    pg_textsearch), pg_fts currently *trails* on raw ranked latency and index
    size — see bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md.  pg_fts stores positional
    postings (for phrase/NEAR) and per-document length, so its index is larger
    and its docid-ordered block-max WAND decodes more per candidate.  Closing
    that gap is a posting-codec change tracked in ROADMAP.md.
  * pg_fts's distinguishing strengths are its query-language breadth
    (phrase/NEAR/prefix/fuzzy/regex over one operator), an index-native
    count(*) that the specialist engines do not expose, and MVCC/crash/
    replication correctness.

fts_bm25_opts variants reproduce Lucene/bm25s scores for conformance.
This is an early (0.1.0) release; ranked performance will iterate.

Known limitations / future work
--------------------------------

  The headline gap is ranked-retrieval latency vs the specialist BM25 engines
  (above); ROADMAP.md tracks the codec direction that closes it.  Other tracked
  ideas:

  * A fully resumable WAND cursor (emit/suspend/resume) instead of the current
    adaptive-k batch-with-growth.  WAND needs the top-k threshold to prune, so
    the batch shape is natural; the adaptive-k form already bounds work to the
    LIMIT actually requested and starts at a full page so common LIMITs are one
    pass.
  * Impact-ordered postings, to let ranked scans over a very common term stop
    earlier than docid-ordered block-max WAND allows.
  * Richer regex trigram tiling (full Navarro (k+1)-tiling / Mihov-Schulz
    automaton, as in pg_tre) beyond the literal-run tiling implemented here.
  * A+C for the trigram index: option C would store the *complement* of a dense
    trigram's term set (small when the trigram is common) with an is_complement
    flag, keeping every stored set <= half the vocabulary.

  Evaluated and deliberately not done: patched-FOR (PFOR) block encoding
  (measured ~<0.5% index saving, not worth the decode complexity); a chained
  overflow segment directory (the size-tiered merge keeps the count far below
  the 128 cap, and the cap raises a clear error rather than corrupting).

Storage architecture
--------------------

The fts index is a set of immutable SEGMENTS plus a small pending write buffer
(the Lucene/Tantivy consensus design):

  * Each segment has a term dictionary (with a sparse per-page block index for
    O(log P) term lookup and sublinear prefix scan), FOR-bit-packed 128-doc
    posting blocks carrying per-block max-tf and min-|D| impact bounds, a
    trigram index over the vocabulary (for fuzzy/regex), and a livedocs
    tombstone bitmap.
  * INSERT appends to the pending buffer (immediately searchable); a flush
    (fts_merge() or VACUUM) folds pending docs into a new segment.  CREATE INDEX
    flushes multiple segments to bound build memory (maintenance_work_mem).
  * A size-tiered merge coalesces similarly-sized segments (dropping tombstoned
    docs), keeping the live segment count small so per-term query cost stays low.
  * DELETE/UPDATE are recorded as per-segment tombstones by VACUUM
    (ambulkdelete); scans and fts_count subtract them, and merges drop them.

Query execution
---------------

  * @@@ boolean/phrase/NEAR/prefix/fuzzy/regex plans as a bitmap scan.
  * ORDER BY d <=> q LIMIT k plans as an index scan (no Sort) driven by
    document-at-a-time block-max WAND (short queries) or MaxScore (>= 4 terms),
    with lazy per-column posting decode so pruned blocks never decode tf/doclen.
  * fts_count(regclass, ftsquery) counts matches in bulk from the index using
    the visibility map (heap probed only for not-all-visible pages).  A plain
    count(*) ... WHERE col @@@ q is transparently answered by this fast path via
    a Custom Scan (FtsCount) -- no need to call fts_count() explicitly.
  * fts_vacuum(regclass) reclaims the physical space left by builds and merges:
    it compacts to one segment reusing the lowest free blocks, then truncates
    the free tail back to the OS (runs automatically during VACUUM when the
    index is substantially bloated).
  * Ranked (<=>/fts_search) results cover merged segments; pending (unflushed)
    docs are found by @@@ and counted by fts_count, and become ranked after the
    next flush (fts_merge() forces one immediately).

Vendored dependencies
---------------------

  * sparsemap v5.3.0 (contrib/pg_fts/vendor/), a compressed-bitmap library used
    for the trigram posting sets and per-segment livedocs tombstones.  All its
    public symbols are namespaced to __pg_bm25_* (via SPARSEMAP_PREFIX in
    vendor/sm.c and the pg_fts_sm.h wrapper), so a second copy loaded by another
    extension in the same backend cannot cause dynamic-linker symbol collisions.

Backward compatibility
-----------------------

tsvector, tsquery, @@, ts_rank and the GIN/GiST opclasses are untouched;
pg_fts is purely additive and opt-in.

Documentation
-------------

User-facing reference documentation is in doc/pg_fts.sgml (rendered in
the "Additional Supplied Modules" appendix as "pg_fts").  This README is the
developer/design overview; CAPABILITIES.md is the production-readiness /
feature matrix (index-AM capability flags, concurrency, replication, and an
honest comparison to tsvector/GIN and ParadeDB pg_search).

Testing
-------

  * sql/pg_fts.sql + expected/pg_fts.out -- the functional regression suite
    (types, query language, the bm25 index, ranking, maintenance, and the
    MVCC/tombstone/oversized-doc correctness edges).
  * specs/bm25_concurrency.spec, specs/bm25_cic.spec -- isolation tests: MVCC
    snapshot stability, pending-list visibility, VACUUM/merge invisibility to
    an open scan, delete+reuse tombstone correctness, and CREATE/REINDEX INDEX
    CONCURRENTLY.
  * t/001_crash_recovery.pl -- an immediate crash + WAL replay reproduces exact
    query answers (GenericXLog crash-safety).
  * t/002_replication.pl -- the index replicates to a streaming standby with
    identical results, including tombstoned deletes.
  * bench/ -- reproducible large-scale benchmarks vs tsvector/GIN and pg_search
    (see bench/RESULTS_*.md).

Run with: make installcheck (REGRESS + ISOLATION + TAP_TESTS), or under meson
meson test pg_fts/... (TAP tests require -Dtap_tests=enabled and the IPC::Run
Perl module).
