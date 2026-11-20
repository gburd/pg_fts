# pg_fts — BM25 full-text search for PostgreSQL

[![CI](https://github.com/gburd/pg_fts/actions/workflows/ci.yml/badge.svg)](https://github.com/gburd/pg_fts/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/gburd/pg_fts?label=release&sort=semver)](https://github.com/gburd/pg_fts/releases)
[![License: PostgreSQL](https://img.shields.io/badge/license-PostgreSQL-blue)](LICENSE)

A PostgreSQL extension for full-text search with true **BM25/BM25F** relevance
ranking, a dedicated `fts` inverted-index access method, and a rich query
language (boolean, phrase, NEAR, prefix, fuzzy, regex).  Unlike the
`tsvector`/`tsquery` + GIN stack, the index maintains the corpus statistics
BM25 needs (document count, average length, per-term document frequency) and
stores term frequency + document length in the posting lists, so ranking is
answered from the index with no heap recheck.

## Benchmarks and comparison

* `bench/BENCHMARK_SUMMARY.md` — current measured results with full methodology
  (rig, corpus, 8-run timing protocol, correctness gate), plus the list of
  optimisations that were tried and **rejected by measurement**, and the record of
  benchmark numbers we published wrong and corrected.
* `doc/COMPARISON_MATRIX.md` — feature/performance matrix against pg_textsearch,
  pg_search (ParadeDB), VectorChord-bm25 and built-in tsvector/GIN, marking
  untested competitor capabilities as untested rather than absent.

## Requirements

- PostgreSQL **17, 18 and 19** are supported and gated in CI (build +
  regression + isolation + TAP on each).  Version differences are handled
  with compile-time guards.
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

The PostgreSQL from the EDB Windows installer is an MSVC build and works as
is: `-Dpg_dir="C:/Program Files/PostgreSQL/18"`.  The check is that
`<pg_dir>\lib\postgres.lib` exists; a PostgreSQL without it cannot link
pg_fts.  (Reported and tested on EDB PostgreSQL 18.6 with Visual Studio 2026
by robinlahtinen, Codeberg #7.)

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

-- BM25-ranked top-k (index-only ordering scan).  The @@@ predicate is required
-- to use the index for the ORDER BY d <=> q KNN scan.
SELECT id FROM docs
 WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'quick fox')
 ORDER BY to_ftsdoc('english', body) <=> to_ftsquery('english', 'quick fox')
 LIMIT 10;

-- fast COUNT (transparent: a plain count(*) WHERE @@@ is pushed to the index).
-- A single plain term on a VACUUMed, tombstone-free index is answered from the
-- dictionary's document frequency alone -- no postings read, no heap touched.
-- Anything else (prefix/fuzzy/regex/weighted/multi-term, pending docs, tombstones,
-- or a heap that is not all-visible) falls back to the exact count automatically.
SELECT count(*) FROM docs
 WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'quick');

-- maintenance (run on the primary; both require index ownership and error on a
-- read replica -- they write WAL)
SELECT fts_merge('docs_bm25');    -- compact segments now
SELECT fts_vacuum('docs_bm25');   -- reclaim disk space (compact + truncate)

-- regex / long-fuzzy acceleration is opt-in (default off):
--   CREATE INDEX ... USING fts (to_ftsdoc('english', body)) WITH (trigrams = on);
-- fts_search()/fts_anomalous_docs() emit indexed content and are REVOKEd from
-- PUBLIC; the index owner and superusers keep access (GRANT to widen).
```

See `doc/pg_fts.sgml` for the full reference (rendered to HTML and published to
[GitHub Pages](https://gburd.github.io/pg_fts/)), `doc/CAPABILITIES.md`
for the feature matrix, `ROADMAP.md` for the roadmap, and
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
series was squashed to a single install script for the first public release
(0.1.0); the public line has since iterated through 0.2.x to 0.3.2, with
in-place `ALTER EXTENSION pg_fts UPDATE` upgrade scripts between releases.

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
    (term~k, Levenshtein DFA), and regex (/re/) terms, with an optional trigram
    pre-filter (`WITH (trigrams = on)`; default off -- regex/long-fuzzy fall
    back to a dictionary scan without it)

    > **Phrase queries need `WITH (positions = on)` to be fast.** The option
    > defaults to **off**, and without it a phrase cannot be verified from the
    > index: the scan falls back to AND plus a **heap recheck** of every
    > candidate document. Measured on 2.19M Wikipedia articles
    > (`bench/NOTE_PHRASE_PROFILE_2026-09-06.md`): ranked top-10 for
    > `"united states"` costs **8,385 ms** with the default and **229 ms** with
    > `positions = on` (**36x**; 1.6-era figures; 1.10.0 runs it in **36.9 ms**
    > with `positions = on`, see Performance); an exact phrase `count(*)` goes **7,170 ms ->
    > 132 ms** (**54x**). The cost is a larger index -- 1,421 MB -> 2,626 MB
    > (1.85x) on that corpus. If you issue phrase or NEAR queries at scale,
    > enable it at CREATE INDEX time.
    >
    > Note also that phrase syntax uses **double** quotes:
    > `to_ftsquery('english', '"united states"')`. Single quotes produce a
    > plain conjunction (`('unit' & 'state')`), which matches many more rows.
  * external-content indexing via an expression index on to_ftsdoc(col)
  * incremental maintenance (INSERT appends to a pending list, no REINDEX);
    background/on-demand merge (fts_merge()) and compaction (fts_vacuum())

    > **Two build-tuning facts worth knowing before your first large index**
    > (measured on 2.19M Wikipedia articles;
    > `bench/RESULTS_GATING_2026-09-09.md`):
    >
    > **1. Raise `maintenance_work_mem` to >= 1GB and the post-build merge
    > disappears.** At that setting this corpus builds straight to a single
    > segment. At PostgreSQL's 64MB default the same build leaves 8 segments plus
    > a **216 s** merge, and the index lands **twice as large** (8,613 MB vs
    > 4,605 MB). If a build is followed by a long merge, this is the first knob to
    > reach for.
    >
    > **2. `max_parallel_maintenance_workers` makes *merges* slower.** It speeds a
    > build up at no durable size cost, but do not raise it for merges.
    > A parallel build is faster (464 s vs 523 s at `maintenance_work_mem=1GB`) and,
    > once `fts_vacuum` has run, **exactly the same size** (1,420 MB either way) --
    > an earlier claim that it was ~17% larger was measured before vacuuming and is
    > withdrawn. The merge finding is solid and separate: a parallel `fts_merge` is
    > **1.45x slower** than serial and leaves 19% more residue, so do not raise this
    > setting hoping to speed up a merge.
  * block-max WAND / MaxScore top-k with lazy per-column decode; fts_search()
    index-only BM25 top-k
  * fts_count(): MVCC-correct bulk count via the index, plus a transparent
    count(*) WHERE @@@ CustomScan pushdown (fires for a stored-column index too,
    not only an expression index); a single plain term over a VACUUMed index is
    answered from the dictionary document frequency alone (~hundreds of times
    faster than decoding the postings)

Query language
--------------

  quick brown          implicit AND
  quick & brown        AND          quick | brown   OR      !slow / -slow  NOT
  (a | b) & c          grouping
  "quick brown fox"    phrase (adjacent)
  quick p/5 fox        ordered proximity, up to 5 token positions apart
  quick w/5 fox        either word order, up to 5 token positions apart
  (dog | canine) w/10 bite   either dog or canine near bite
  NEAR(quick fox, 5)    ordered proximity (existing syntax)
  a w/3 b w/5 c        chained proximity (left associative)
  "summary judgment" w/5 negligence   phrase proximity
  breach <2> contract  exact two-position gap
  quick*               prefix
  quick~2              fuzzy, edit distance <= 2
  /^qu.*x$/            regex over each term
  title AND fox        keyword operators (AND/OR/NOT, case-insensitive)

`w/N` accepts terms, phrases, OR alternatives, and nested proximity groups.
It joins nonoverlapping matches whose nearest edges are 1..N token positions
apart, in either order (adjacent words have distance 1). Chaining is left
associative; parentheses change grouping. All matching spans are retained.
For example, `(a w/3 b) w/5 c` puts `c` near either outside edge of the `a`/`b`
match. `p/N` and `NEAR` retain their historical ordered endpoint semantics.
AND/NOT directly inside proximity are rejected because they have no span.

Quoted phrases use exact adjacency, with removed stopwords preserving their
spacing: `to_ftsquery('english','"breach of contract"')` yields
`'breach' <2> 'contract'`. Exact `<N>` includes `<0>` for the same position.
Prefix, fuzzy and regex terms work positionally inside phrases. Prefixes may
also carry weights (`attorn*:A`); fuzzy+weight and regex modifiers error.

Use `WITH (positions=on)` for compound proximity without heap rechecks, also
when combined with AND and NOT. Weighted/expanded terms still use exact
rechecks, and so does a document whose positions were not stored or are
oversized (that document alone).
Since 1.15.0 the configured analyzer (`to_ftsdoc(config, text)`) keeps positions
past PostgreSQL's 16,383-position cap, as the unconfigured `to_ftsdoc(text)` always
did.  A stored `ftsdoc` column or expression index built by an earlier release keeps
the capped positions until it is recomputed or rebuilt (see Upgrading).

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

### pg_fts 1.18.0 vs the field on bare metal, PostgreSQL 18.7 and 19.0 (2026-11-19/20)

`bench/RESULTS_FIELD_METAL_2026-11-19.md`; protocol (written before the run, with its
amendments): `bench/PROTOCOL_FIELD_METAL_2026-11-19.md`; raw data, harness and the full
generated tables: `bench/data_field_metal_2026-11-19/`.

**Method.**
- **Arms.**  pg_fts **1.18.0** (PGXN zip, sha256-verified), pg_textsearch **1.5.1** and
  **main** `8923a5ba` (1.6.0-dev, the only pg_textsearch that builds on 19.0), pg_search
  **0.27.0** (ParadeDB's RPM) as shipped and with `pnorms=true`, VectorChord-bm25
  **0.3.0**, and built-in **GIN** on a stored `tsvector` ranked with `ts_rank`.  On 19.0:
  pg_fts, pg_textsearch main and GIN (pg_search and VectorChord do not ship for it).
- **Hosts.**  Four EC2 bare-metal hosts: **2x c6id.metal** (Xeon 8375C, 128 vCPU) and
  **2x c7gd.metal** (Graviton3, 64 vCPU).  Fedora 45; XFS on one local NVMe device.  Every
  arm ran on every host, one cluster at a time, from one PostgreSQL build per major.
- **Data.**  The 2,188,038-article Wikipedia corpus, md5-checked on every host.
- **Correctness first.**  pg_fts, pg_textsearch and GIN count `year` identically
  (734,896) on both majors, and pg_fts's and pg_textsearch's 19.0 top-k ids equal their
  18.7 ids.  Every engine's top-100 was rescored under one fixed BM25.
- **Latency.**  The median of the last 5 of 8 runs in one session, over 5 passes in
  rotated order, with an A/A arm (spread 0.0-4.5%).  A difference is called only when the
  pass spreads separate on both hosts of an architecture by more than 3x the A/A spread.
- **Also measured.**  Settled throughput at 1-256 clients, cold first query, build, size.

| median ms, single client, PG 18.7 (x86 / arm) | **pg_fts 1.18.0** | pg_textsearch 1.5.1 | pg_search 0.27.0 | pg_search pnorms | VectorChord | GIN |
|---|---|---|---|---|---|---|
| rare `slovakia` top-10 | **0.23 / 0.24** | 0.91 / 0.98 | 1.18 / 1.19 | 1.04 / 1.02-1.06 | 8.7 / 11.2 | 55 / 42 |
| common `year` (df 735k) top-10 | **0.36 / 0.35** | 9.9 / 10.7 | 1.22-1.26 / 1.22-1.24 | 1.18-1.23 / 1.17-1.20 | 55 / 68 | 2,347-2,672 / 1,699-1,712 |
| common top-1000 | 13.4 / 11.8 | 14.0 / 15.1 | 7.6-7.8 / 8.4 | **5.8 / 5.7** | (returns 100 rows) | 2,345-2,704 / 1,708 |
| 2-term OR top-10 | 1.31 / 1.30 | **1.28 / 1.27** | 1.81 / 1.80 | 1.62 / 1.55 | 5.6 / 7.0 | 167 / 140 |
| 4-term OR top-10 | 15.7 / 12.6 | 15.8 / 13.9-14.1 | 10.4-10.6 / 9.2-9.3 | **10.1 / 9.1-9.2** | 32 / 37 | 1,719 / 1,245-1,258 |
| `slovakia & hungary` top-10 | **0.67 / 0.64** | 5.0 s / 4.0 s (as a CTE; >300 s plain) | 1.60 / 1.60 | 1.38 / 1.34 | n/a | 19 / 19-20 |
| `united & states` top-10 | **2.16 / 1.89-1.93** | >300 s / 275 s as a CTE | 9.2 / 8.6-8.8 | 9.2-9.5 / 8.6-8.8 | n/a | 1,583-2,712 / 1,869 |
| `world & war` top-10 | 6.27 / 5.52 | 190 s / 150 s as a CTE | 2.85-2.93 / 2.85-2.98 | **2.18-2.27 / 2.26-2.35** | n/a | 1,123-1,231 / 926-934 |
| `"united states"` top-10 | **2.56 / 2.38-2.44** | >300 s | 8.9-9.0 / 8.7-8.9 | 9.4-9.6 / 8.6-8.9 | n/a | 2,090-3,294 / 2,642-2,655 |
| exact count of `year` | **0.18 / 0.16** | 291 s / 233 s | 0.95 / 0.90 | 0.96-0.99 / 0.91-0.93 | n/a | 552-578 / 400-406 |
| settled tps, rare top-10, 64 clients | **119,720-122,464 / 144,415-148,213** | 17,776-20,225 / 12,232-20,211 | 46,980-47,150 / 48,769-48,802 | 52,643-52,657 / 56,397-57,407 | 2,531-2,551 / 1,609-1,732 | 446-459 / 458-468 |
| build, default index | 255-256 s / 239-240 s | 298-299 s / 266 s | **118-130 s / 123-124 s** | 134 s / 112-128 s | 3,377-3,378 s / 3,182-3,202 s (model + tokenize + index) | 1,053-1,057 s / 855-859 s (column + index) |
| index size | **1,369 MiB** | 1,887 MiB | 2,308 MiB | 2,704 MiB | 42,435 MiB | 1,569 MiB + 6,349 MiB column |

  * **Where pg_fts wins** (STABLE on both architectures).  Ranked single terms at every
    frequency up to top-100: 3.9-4.1x pg_textsearch and 4.9-5.1x pg_search on a rare term,
    27.5-31x and 3.4-3.5x on a common one.  Conjunctions led by a rarer term
    (`slovakia & hungary` 2.4-2.5x pg_search, `united & states` 4.3-4.6x), phrases
    (`"united states"` 3.5-3.6x, `"world war"` 1.37-1.49x), and the exact count (5.4-5.6x
    pg_search).  pg_textsearch's boolean, phrase and count forms have no index path and take
    seconds to over 300 s.  Throughput under load: 2.5-3.0x pg_search and 5.9-12x
    pg_textsearch on a rare term at 64 clients.  The smallest index.  One operator for the
    full query language (phrase, NEAR, prefix, fuzzy, regex, field zones), exact top-k
    (no early termination), MVCC-correct results, and crash, replication and corruption
    testing.
  * **Where pg_fts does not win.**  pg_search builds about 2x faster.  It is faster on a
    common term's top-1000 (pg_fts 1.4-1.8x slower; 2.1-2.3x with `pnorms`), on the 4-term
    OR (1.35-1.6x), on `world & war`, where both terms are frequent (1.85-2.9x), and on
    `hungary & !slovakia` (1.04-1.19x).  pg_textsearch ties pg_fts on the 2-term OR (no
    claim), and on the 4-term OR on x86; it is faster on a cold first query for a single
    term (14-25 vs 41-46 ms rare, 26-43 vs 47-55 ms common).
  * **PostgreSQL 19.0.**  pg_fts 1.18.0 performs the same on 19.0 as on 18.7 (same host,
    ratio 0.945-1.036 across bands, no claim), and its 19.0 results equal its 18.7 results.
    Against pg_textsearch main on 19.0 the ratios are the same as on 18.7.
  * **On TIN's published rig** (`bench/RESULTS_M4_2026-10-29.md`, EC2 i7i.8xlarge, 8 vCPU /
    32 GB per engine, 59.7M Stack Overflow posts, a synthetic 2-15-word query trace, one run
    per engine): against pg_search 0.25.2, pg_fts 1.15.1 is ahead on conjunctions and phrases
    (125 vs 53 tps, p99 626 vs 1,511 ms).  It is behind on long disjunctions (mean 1,555 vs 334
    ms; mixed workload 26 vs 45 tps) and far behind on concurrent updates (25 vs 999 UPDATEs/s
    at a 1,000/s target, readers 1.7 vs 26.7 tps).  Its build needed 132-141 GB with
    `maintenance_work_mem = 24GB` (pg_search 64 GB).  ROADMAP I21, I22.
  * **Relevance** (`bench/RESULTS_1144_2026-10-28.md`, BEIR test qrels, pg_search
    0.26.1, x86): NDCG@10 on SciFact 0.685 (pg_fts, English) vs 0.634 (pg_search) vs
    0.568 (ts_rank); on NFCorpus 0.324 vs 0.300 vs 0.300.  With no stemming (`simple`)
    pg_fts scores 0.665 / 0.302.  Two datasets only.
  * **What is not compared.**  Write throughput (the 2026-10-15 and 1.11.0 runs have
    concurrent-write bands), network storage, replicas, and relevance on this corpus.

fts_bm25_opts variants reproduce Lucene/bm25s scores for conformance.
Ranked-retrieval performance continues to iterate (see ROADMAP.md).

Known limitations / future work
--------------------------------

  Build time trails pg_search (above); ROADMAP.md tracks the remaining work.  Other
  tracked ideas:

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
    posting blocks carrying per-block max-tf and min-|D| impact bounds, an
    optional trigram index over the vocabulary (fuzzy/regex; built only
    `WITH (trigrams = on)`, default off), and a livedocs
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
    it compacts to a single segment (relocating live pages toward the front of
    the file) and truncates the freed tail back to the OS (runs automatically
    during VACUUM when the index is substantially bloated).  A single call
    reclaims most of the space; a second converges to the floor -- measured
    2026-09-09, one call left ~4.7% above the live floor on a 2.19M-doc index,
    which matches what the reference documentation already stated.

    > **How much space this is, measured.** After a 2.19M-document build at
    > `maintenance_work_mem=1GB`, `pg_relation_size` was **4,406 MB** but only
    > 173,529 pages were live (**1,355 MB**) — 69% of the file was already-freed
    > pages. `fts_vacuum` reclaimed all of it: **4,406 → 1,355 MB**. Live pages
    > average **98.8% full**, so this is not a packing problem; it is that a merge
    > allocates its output by extending the file, and the truncation step can only
    > return a *contiguous free tail* — with the final output sitting at the top of
    > the file, the freed pages beneath it need the compaction pass to move live
    > data down before anything can be truncated.
    >
    > **Unattended autovacuum holds the index bounded, and reclaims after deletes — no
    > scheduled maintenance required.** Measured at 1M docs with autovacuum on and no
    > manual maintenance at all: five consecutive cleanups with nothing changed stayed
    > **flat at 511 MB**; six rounds of insert + delete churn stayed **flat at 875 MB**;
    > and after deleting half the table, cleanup brought the index **875 → 106 MB (8.3×)**
    > with queries served throughout and results exact
    > (`bench/RESULTS_P1_SCALE_AB_2026-09-13.md`).
    >
    > Earlier releases did grow per vacuum pass. Two 2026-09-12 fixes (a merge truncates
    > the free tail it creates; cleanup truncates unconditionally) cut that ~**6×**, and a
    > 2026-09-13 fix removed the rest at small scale by skipping a compaction pass whose
    > free space is not yet reusable — a pass run right after a merge would otherwise
    > relocate live data upward and reclaim nothing, since the pages it just freed are
    > still visible to its own transaction.
    >
    > `fts_vacuum` is still useful for a **one-off** tighter reclaim — it always does the
    > full repack, reaching ~3x smaller than the automatic steady state — so it is worth
    > running once after a large initial build or a mass delete. It is not required to
    > prevent growth. Measurements in
    > `bench/DIAG_WORKER_FRAGMENTATION.md`.
    >
    > **Incremental INSERTs can grow the file far beyond the settled index size, if your
    > documents are large.** A pending document is stored **verbatim**, and one that does
    > not fit in an 8 KB page is indexed immediately as its own **one-document segment**.
    > On a Wikipedia corpus 33% of documents exceed that threshold, and inserting 200k
    > rows into a settled 792 MB / 1M-doc index grew the file to **32 GB before any merge
    > ran**; `fts_merge` added only ~7% on top, and `fts_vacuum` then returned it to
    > 971 MB. Measured at two scales (`bench/RESULTS_C2_INGEST_2026-09-11.md`).
    >
    > This is corpus-dependent, not a general rule: it scales with the *fraction of your
    > documents larger than a page*, so a corpus of short documents will not see it.
    > If you bulk-INSERT large documents, merge and `fts_vacuum` periodically rather than
    > accumulating, and provision headroom accordingly.  Compaction rewrites the live data before freeing
    the old copy (write-before-free, for crash safety), so it transiently needs
    free disk space of roughly the live index size -- like VACUUM FULL / CLUSTER
    / pg_repack.  It is interruptible: pg_cancel_backend and statement_timeout
    stop it promptly, and a cancelled (or out-of-disk) run leaves the index
    valid and correct, just not fully compacted.
  * Ranked (<=>/fts_search) results include pending (unflushed) documents,
    scored exactly as they will be after the next flush, and the documents a
    prefix/fuzzy/regex term matches only through an expansion (an exact heap
    fallback; ranking still scores literal query terms, so such a match can
    score zero).  Equal scores use TID order, keeping pagination stable.

Vendored dependencies
---------------------

  * sparsemap 5.8.5 (vendor/), a compressed-bitmap library used for the trigram
    posting sets and per-segment livedocs tombstones.  All its
    public symbols are namespaced to __pg_bm25_* (via SPARSEMAP_PREFIX in
    vendor/sm.c and the pg_fts_sm.h wrapper), so a second copy loaded by another
    extension in the same backend cannot cause dynamic-linker symbol collisions.

Upgrading
---------

Install the new build, then `ALTER EXTENSION pg_fts UPDATE`; no release since
1.5.0 needs a REINDEX for a format change.  **But an index that took writes under
1.10.0 or earlier must be rebuilt** (`REINDEX INDEX`, or `REINDEX INDEX CONCURRENTLY`
to keep it online): it can return rows that do not match and miss rows that do, and
the upgrade does not repair either.  Rebuild it whatever a check says; CHANGELOG
1.14.2 has the cause and the SQL checks (run them with bitmap scans off).

From 1.15.0, `to_ftsdoc(config, text)` stores the true position of every token of a
document longer than 16,383 tokens (earlier releases gave every later token position
16,383).  Values computed before the upgrade keep the old positions, so a phrase or
NEAR past that point still does not match them: recompute a stored column
(`UPDATE t SET d = to_ftsdoc('english', body) WHERE ftsdoc_length(d) > 16383`) and
`REINDEX` an expression index over `to_ftsdoc(config, ...)` to gain them.  Nothing
else changes for shorter documents.  1.15.0 split HTML markup at its internal chunk
boundaries in such documents (tag attribute words indexed, positions shifted); recompute
values 1.15.0 computed from long markup after installing 1.15.1.

1.15.2 needs nothing after the upgrade.  Ranked queries on an index whose single
packed segment carries many scattered tombstones (a bulk DELETE, then VACUUM) are
fast again without a REINDEX (CHANGELOG 1.15.2).

1.16.0 needs nothing after the upgrade.  `fts_vacuum` now drops the tombstones of a
single packed segment too (it returns true and rewrites the segment under its
AccessExclusiveLock), so a REINDEX is no longer the only way to reclaim them.  An
index with segments merged by 1.5.0-1.5.2 that was never reindexed (1.5.3 asked for
it) now ranks them without reading past a block, but their length normalisation is
still approximate: REINDEX them (CHANGELOG 1.16.0).

1.18.0 needs nothing after the upgrade (no SQL or on-disk change).  It vendors
sparsemap 5.9.0 and supports PostgreSQL 19.0; an assert-enabled server no longer
aborts an autovacuum worker that vacuums an fts index (CHANGELOG 1.18.0).

1.17.0 changes scores after deletes: the document count and average length now drop
deleted rows when VACUUM tombstones them, so a ranked query scores as it would after a
REINDEX of the same rows.  An index that deleted rows under an earlier release keeps
the old average until one `fts_vacuum` (or `fts_merge`) leaves it with no tombstones,
or a REINDEX (CHANGELOG 1.17.0).  `fts_index_segments(index)` shows each segment's
tombstones.  1.17.0 builds against PostgreSQL 19.

Backward compatibility
-----------------------

tsvector, tsquery, @@, ts_rank and the GIN/GiST opclasses are untouched;
pg_fts is purely additive and opt-in.

New `tsquery` casts preserve exact phrase gaps. Existing stored ordered-query
values retain their historical maximum-gap interpretation. Text saved by an
older lossy serializer cannot recover a distance that was already discarded.

Documentation
-------------

User-facing reference documentation is in doc/pg_fts.sgml (rendered in
the "Additional Supplied Modules" appendix as "pg_fts").  This README is the
developer/design overview; doc/CAPABILITIES.md is the production-readiness /
feature matrix (index-AM capability flags, concurrency, replication, and an
honest comparison to tsvector/GIN and ParadeDB pg_search).

Testing
-------

  * sql/pg_fts.sql + expected/pg_fts.out -- the functional regression suite
    (types, query language, the bm25 index, ranking, maintenance, and the
    MVCC/tombstone/oversized-doc correctness edges).
  * sql/legal_proximity.sql -- an independent occurrence-span oracle, including
    nested proximity, exact phrases, expansions, stopwords and query roundtrips.
  * test/query_binary.py -- 49 valid/malformed binary-query checks; run only in
    a disposable server (`pg_virtualenv python3 test/query_binary.py --local`).
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
