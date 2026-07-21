# Changelog

All notable changes to pg_fts are documented here.

## 1.0.3

Bug-fix release. **No on-disk format change** from 1.0.2; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.3'`).

- **Fixed an `invalid memory alloc request size` crash in a parallel index-build
  worker** (reported against a ~13-hour parallel `CREATE INDEX CONCURRENTLY`
  over a large table with a very large vocabulary). This was a different site
  from the 1.0.2 fix: the trigram inverted-index builder and the streaming
  segment merge sized several allocations from the *merged-group vocabulary*,
  which -- unlike the per-segment build path -- is not bounded by
  `maintenance_work_mem`, so a hot trigram's term list (and the merge output
  arrays) could exceed the 1 GB allocation limit on a large enough corpus. All
  corpus/vocabulary-scale allocations in the build, merge, and analyze paths now
  use a huge-safe allocation, closing this crash class off across the board.
- **A single document that would assemble into an `ftsdoc` larger than 1 GB now
  reports a clear "document is too large" error** instead of an opaque
  allocation failure. An `ftsdoc` is a variable-length value limited to 1 GB.

## 1.0.2

Bug-fix release. **No on-disk format change** from 1.0.1; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.2'`).

- **Fixed a read-path crash (`invalid memory alloc request size`) when decoding
  a posting block with a very large per-block position count.** The
  positions-decode path in `bm25_decode_term` sized its scratch buffers with an
  unguarded allocation; when a block's summed term frequency pushed the buffer
  past the 1 GB `MaxAllocSize` limit, the allocation threw and aborted whatever
  triggered the decode -- a `CREATE INDEX CONCURRENTLY` validation scan in the
  reported case, but the same path is reached by ordinary scans (count, ranked,
  phrase), merges, and vacuum. A legitimately large position count now uses a
  huge-safe allocation; a corrupt or inflated on-disk term-frequency (a class
  the existing block-header and column-length corruption checks did not catch)
  is now detected and rejected with a `WARNING` (a bounded miss, `REINDEX` to
  rebuild), rather than reading past the block. This was the read-side
  counterpart of the build-time huge-allocation fix; both sides are now guarded.
- The corruption/fuzz harness gained a dedicated planted-bug ("teeth") build for
  this class, so a regression that removed the guard would fail CI.

## 1.0.1

Bug-fix release. **No on-disk format change** from 1.0.0; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.1'`).

- **Fixed an out-of-memory crash when building or merging a large index.** The
  segment-merge phase (used by the final compaction of an index build, by
  `fts_merge`, and by parallel builds) decoded every posting of every term from
  all merged segments into memory at once before writing the result, so
  compacting a large index could hold the entire index's postings in RAM and
  OOM the server. Merging is now a bounded, streaming k-way merge that holds
  only one term's postings at a time; peak merge memory is independent of index
  size. Measured on a 3M-document build: peak merge memory dropped from 2240 MB
  to ~1 MB, with the same result and no build-time regression. No on-disk
  format change and results are unchanged (index-vs-sequential-scan parity, with
  positions, tombstone drops, and phrase queries all preserved).

## 1.0.0

First stable release. **No on-disk format change** from 0.3.x; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.0'`). The on-disk format
(BM25_VERSION 3, FTS_DOC_VERSION 3) and the SQL surface are now considered
stable; future 1.x releases keep backward compatibility.

- **`fts_vacuum` now converges and reclaims space in a single call, never
  grows the index, and is interruptible.** Compaction previously could
  oscillate (transiently grow the index before shrinking) and, in a first
  correctness pass, could stabilize without reclaiming dead space; and no pg_fts
  operation checked for interrupts, so a long build/merge/vacuum could not be
  cancelled. `fts_vacuum` now compacts to the size floor in one call, is stable
  across repeated calls, and never returns larger than it started. It honors
  `pg_cancel_backend` and `statement_timeout` (nine interrupt-check points along
  the merge/vacuum path); a cancelled or out-of-disk run leaves the index valid
  and correct, just not fully compacted. Because compaction rewrites live data
  before freeing the old copy (for crash safety), it transiently needs free disk
  space of roughly the live index size, like `VACUUM FULL` / `CLUSTER` /
  `pg_repack`.
- **The transparent `count(*) ... WHERE col @@@ q` fast path is now chosen at
  scale.** The `FtsCount` custom-scan cost model was priced against the whole
  heap and lost to a bitmap index scan on large tables; it is now priced as the
  index-only visibility-map count it actually performs, so the planner uses the
  faster path automatically.
- **Supported versions.** PostgreSQL 17 and 18 are fully supported and gated in
  CI (regression + isolation + TAP). PostgreSQL 19 / `master`-devel builds and
  is exercised best-effort (it is unreleased).
- **Testing.** The TAP suite (crash recovery, replication, torn-page recovery,
  server-encoding install/parity) is now a gating part of CI on both forges,
  alongside regression + isolation, AddressSanitizer / UndefinedBehaviorSanitizer
  builds, a fuzz harness for the posting-decode path, property-based tests, and a
  line-coverage floor.

## 0.3.6

- **`fts_snippet` default ellipsis is now ASCII `...` (was the UTF-8 `…`).** The
  non-ASCII default made `CREATE EXTENSION pg_fts` FAIL on a non-UTF-8 server
  database (LATIN1, EUC_JP, ...) with "invalid byte sequence for encoding" --
  pg_fts was uninstallable there. The install SQL is now pure ASCII (guarded by
  `make check-ascii` in CI on both forges), so pg_fts installs on every server
  encoding. Callers who want the `…` glyph pass it explicitly:
  `fts_snippet(doc, q, ellipsis => Eu2026)`.
- **Character-encoding / multi-script correctness is now permanently tested.** A
  UTF-8 regression block asserts pg_fts `@@@` == native `to_tsvector @@` across
  14 scripts (Latin, Windows-1252 punctuation, CJK Han, Japanese, Hangul, NFC vs
  NFD combining marks, emoji + 4-byte astral, CJK Ext-B, Arabic/Hebrew RTL,
  Turkish dotless-i, German sharp-s), plus a corner-case block (fold-length
  changes, multi-mark combining, ZWJ, BOM, fullwidth, Cyrillic) exercising the
  built-in analyzer; and `t/004_encodings.pl` gates LATIN1 + EUC_JP *server*
  encodings (install + native parity on high/multibyte bytes).

## 0.3.5

Hardening + testing release. **No on-disk format change**; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '0.3.5'`).

- **Further hardened the segment posting-decode path** against corrupt/torn
  pages (three issues found by the new fuzz harness, extending the 0.3.4 fix):
  the per-block `count` clamp was one-sided (a `uint32` count >= 2^31 cast to a
  negative `int` and slipped past `> BM25_BLOCK_SIZE`) and is now tested on the
  unsigned value; the three FOR columns' width-driven byte consumption is now
  bounded against the block's declared `bytelen` before decoding, so a corrupt
  width byte cannot read past the page; and a shift-by-64 undefined behavior in
  `bm25_for_unpack` on a corrupt width (> 64) is fixed (valid widths unaffected).
  A corrupt block remains a bounded miss with a `WARNING`, never a crash.
- **New testing regime** (see `doc/testing.md`), run in CI on both forges:
  an AddressSanitizer+UBSan build of the regression + isolation suite; a gating
  fuzz/corruption harness (`test/fuzz/`) over the FOR codec, the stored-document
  validator, and the block decoder, with planted-bug "teeth"; property-based
  tests (`test/hegel/`) for the codec + validator invariants; a torn-page
  crash-safety TAP test (`t/003_corruption.pl`); and a **90% line-coverage gate**
  on the pg_fts sources. `fts_doc_is_valid`'s logic was factored into a pure
  header (`pg_fts_docvalid.h`) shared with the fuzzer (behavior-identical).


## 0.3.4

Crash-safety bug-fix release. **No on-disk format change**; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '0.3.4'`).

- **Fixed an intermittent crash in the segment posting-decode path**
  (`fts_doc_matches` <- `bm25_collect_matches` <- `bm25_gettuple`), a follow-on to
  the 0.3.3 pending-list fix that its validator did not cover. `bm25_decode_term`
  read a posting block header's `count` from disk and unpacked that many values
  into fixed 128-element (`BM25_BLOCK_SIZE`) stack arrays (`gaps`/`tfs`/`dls`)
  **with no bound check** -- a torn or corrupt block header with `count >
  BM25_BLOCK_SIZE` overflowed the stack (an AddressSanitizer heap/stack-buffer-
  overflow, reproduced against the FOR codec). The WAND block loader already
  clamped its count; this decoder (used by the boolean/`@@@`/count-pushdown/
  ranked/anomaly/trigram scan paths -- every `bm25_decode_term` caller) did not.
  It now clamps the per-block count to `BM25_BLOCK_SIZE` and stops decoding a
  block whose declared column byte lengths (`bytelen`/`posbytelen`) run past the
  page, so a corrupt block is a bounded miss (with a `WARNING` hinting `REINDEX`)
  instead of a crash. Fixing it inside `bm25_decode_term` protects all callers at
  once. Valid indexes are unaffected; a regression test decodes a large
  multi-block posting list (df >> 128, with positions).


## 0.3.3

Crash-safety bug-fix release. **No on-disk format change**; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '0.3.3'`).

- **Fixed two backend crashes on the pending-list path** (reported on 0.3.2 /
  PostgreSQL 18 under heavy concurrent write load): a `_FORTIFY_SOURCE` buffer
  overflow (SIGABRT) in `add_posting` during the autovacuum pending-list flush,
  and a SIGSEGV in `fts_doc_matches` while scanning pending documents. Both
  stemmed from the pending-list readers casting raw index-page bytes to an
  `ftsdoc` and trusting its term metadata (`nterms`, per-term `len`/`tf`/
  `posoff`) without validation, so a malformed or torn page turned a bad length
  into a wild `memcpy` or a bad offset into an out-of-bounds read. The flush
  (`bm25_vacuumcleanup` -> `bm25_flush_pending`) and scan
  (`bm25_gettuple` -> `bm25_collect_matches`) paths now validate each pending
  document's structure against its own byte length (`fts_doc_is_valid`) before
  trusting any offset, and skip a malformed document with a `WARNING` (hinting
  `REINDEX`) instead of crashing the backend. `add_posting`'s fixed-size term
  key also clamps its length defensively as a last line of defense. Valid
  documents are unaffected. A crash-regression test covers the long-token
  pending -> scan -> flush cycle.


## 0.3.2

Additive release. **No on-disk format change**; no **REINDEX** required for the
extension upgrade (`ALTER EXTENSION pg_fts UPDATE TO '0.3.2'`). Indexes over
non-ASCII text should be `REINDEX`ed to pick up the new Unicode lowercasing;
ASCII-only indexes are unaffected.

- **`pg_stat_user_indexes` now reflects bm25 index usage** (PR #5, dinesh-salve).
  Every query path that reads the index registers an index scan
  (`pgstat_count_index_scan`), so `idx_scan`/`last_idx_scan` are no longer stuck
  at 0: the bitmap scan, the plain + ranked (`ORDER BY <=>`) index scans, the
  `count(*)` pushdown / `fts_count()`, and native `fts_search()` top-k.
  `idx_tup_read` is reported on the bypass paths too (the AM scan paths already
  get it from the generic index layer). A bare `ORDER BY <=>` with no `@@@`
  filter is a seq-scan+sort and correctly stays at 0.
- **Unicode lowercasing in the built-in analyzer** (PR #4, dinesh-salve). The
  built-in `to_ftsdoc(text)`/`to_ftsquery(text)` analyzer folded only ASCII
  `A-Z`, so accented text never matched case-insensitively (`'CAFÉ'` missed
  `'café'`). A shared `fold_token()` (used by the document analyzer, the query
  lexer, and the aux tokenizer, so both sides fold identically) now lowercases
  non-ASCII tokens per Unicode code point via `unicode_lowercase_simple()` in
  UTF-8 databases; non-UTF-8 databases keep byte-wise ASCII folding. Simple
  lowercasing, not full case folding (`'ß'` stays `'ß'`), matching pg_search's
  default, and `to_ftsdoc()` stays `IMMUTABLE`. **No on-disk format change**;
  ASCII-only indexes are unaffected. Indexes over non-ASCII text built before
  this change should be `REINDEX`ed (their stored terms are unfolded).
- **Build-time huge-allocation fix for very high-df terms.** At large diverse
  corpora (found while benchmarking at 20M docs -- see `bench/RESULTS_20M.md`) a
  single ultra-common token's build-time posting arrays can exceed `MaxAllocSize`
  (1 GB), which plain `palloc` rejects, aborting the index build. `add_posting`,
  `bm25_decode_term`, and `bm25_write_postings` now use the `...Huge` allocation
  variants past 1 GB. No format change.

## 0.3.1

Additive feature release. **No on-disk format change** (read-only over the
existing index) and no **REINDEX** required. `ALTER EXTENSION pg_fts UPDATE TO
'0.3.1'`.

- **Lexical anomaly detection: `fts_anomalous_docs(index, k, max_df)`.** A
  set-returning function that surfaces the top-`k` most lexically-anomalous
  documents in an fts index -- those containing globally **rare** terms. A
  document's anomaly score is the maximum idf over its terms (driven by its
  single rarest term), using the same rarity value BM25 uses:
  `idf = log(1 + (N - df + 0.5)/(df + 0.5))` on the **global** df (a term's df
  is summed across all segments before scoring, so a document split across two
  segments is not made to look artificially rare). Returns
  `(ctid tid, score float8, rarest_term text, min_df int)` ordered by score
  DESC, limit `k`.
  - **Cheap because it walks only the low-df tail.** The rarest terms have the
    shortest posting lists, so the function walks the term dictionary and
    **skips any term whose global df exceeds `max_df` before decoding a single
    posting** -- the common, high-df bulk of the dictionary is never decoded.
    On a 1M-document corpus with a handful of injected unique tokens, the query
    returns those docs in **well under a millisecond** (measured 0.6 ms), not a
    full-corpus scan. `max_df` defaults to `max(N/1000, 1)` when NULL, keeping
    the walk on the low-df tail.
  - The returned ctids are index-resident heap pointers (like `fts_search`);
    this is an analytic/heuristic result, so no per-doc heap visibility check is
    done -- join `ctid` back to the table and filter for visibility if needed.
    Per-segment tombstones are honored, so deleted documents are not reported as
    anomalies.
  - Lexical only: it catches rare/novel *wording and tokens*, not semantic
    novelty (see `bench/NOTE_ANOMALY_DETECTION.md`). Bench harness in
    `bench/anomaly.sql`.
- **Fixed `ftsdoc` text I/O round-trip (Codeberg #3).** `ftsdoc_out` emitted the
  canonical `'term':tf` form but `ftsdoc_in` re-tokenized that string as raw
  text, so `ftsdoc_in(ftsdoc_out(x)) != x` -- text `COPY`/`pg_dump --inserts` of
  stored `ftsdoc` columns corrupted the data. `ftsdoc_in` now parses the
  canonical grammar `'term':tf[@p1,p2,...]` (falling back to raw-text analysis
  for the ergonomic `'the quick brown fox'::ftsdoc` cast), and `ftsdoc_out`,
  `ftsdoc_send`/`ftsdoc_recv` now carry per-token **positions** so both text and
  binary I/O are faithful, position-preserving round-trips. Input is validated
  at the trust boundary (ascending/distinct terms, `tf>=1`, ascending positions,
  `tf` positions per term; corrupt binary bounded before palloc). The `ftsdoc`
  binary wire version bumped 2 -> 3; `ftsdoc_recv` still **accepts v2** so a
  `pg_dump -Fc` taken under an older pg_fts restores cleanly (v2 docs are
  position-free). No on-disk index format change.

## 0.3.0

Feature release with an **on-disk index format change (BM25 v2 -> v3)**. Existing
bm25 indexes must be **REINDEX**ed; the format guard rejects a v2 index with a
REINDEX hint. No `ftsdoc`/`ftsquery` type change.

- **Token positions in the postings, gated by a new `positions` reloption.**
  `CREATE INDEX ... USING fts (...) WITH (positions = on)` stores per-token
  positions in the posting blocks (a 4th, lazily-decoded frame-of-reference
  column after docid-gaps/tf/doclen). Phrase and NEAR queries are then answered
  **directly from the posting lists** -- intersect on docid, verify adjacency
  from the stored positions via the same `phrase_step` logic the heap recheck
  uses -- with **zero heap access and no recheck**. This removes the phrase/NEAR
  count cliff (a common two-word phrase count over an expression index dropped
  from seconds to the AND-count range in local tests) for both the expression
  index (`to_ftsdoc(col)`) and the stored-`ftsdoc`-column shapes.
  - **Default is `positions = off`**: positions roughly double the posting bytes
    on high-term-frequency corpora, so the size-sensitive majority who never
    phrase-search pay nothing. Phrase/NEAR is **always correct** either way; it
    is only fast (index-only, no recheck) with `positions = on`. With
    `positions = off` it falls back to the correct-but-slower heap recheck.
  - Positions are decoded **lazily**: plain BM25 ranked / boolean AND / count
    queries never read or decode the positions column (a `posbytelen`-guided
    pointer skip, mirroring the existing tf/doclen skip), so a non-phrase query
    pays ~zero for positions existing (measured: no regression vs v2 on a
    common-term ranked/count query).
  - `fts_vacuum` / merge carry positions through the compaction rewrite and keep
    reclaiming space; a pathological per-(term,doc) term frequency whose
    positions would overflow a page drops that block's positions and phrase
    falls back to recheck for those docids (correctness preserved).

## 0.2.4

Bug-fix release. The fix is in the shared library; no SQL objects change and no
REINDEX is required. `ALTER EXTENSION pg_fts UPDATE TO '0.2.4'`.

- **Phrase / NEAR queries silently returned wrong results on a *stored* `ftsdoc`
  column.** The positions[] region of a document was addressed as
  `MAXALIGN(absolute-pointer)`, but the analyzers lay it out at
  `base + MAXALIGN(offset)`. For a heap-resident (detoasted) document whose base
  is not itself MAXALIGN'd, `MAXALIGN(base+off) != base+MAXALIGN(off)`, so the
  position array was mis-addressed and phrase/NEAR degraded to a plain AND
  (matching any document containing the terms, ignoring adjacency). Fixed to the
  offset-based address. Expression indexes on `to_ftsdoc(col)` were unaffected
  by this bug (freshly-analyzed, always-aligned documents); short documents in
  the existing tests happened to remain aligned, which is why it was missed.
- Note: phrase *count* over an expression index on a common two-word phrase is
  still slow (it rechecks the whole AND-set against the heap, re-analyzing each
  document). A positional-index format change in a later release removes that
  heap recheck; this release only fixes the stored-column correctness bug.

## 0.2.3

Performance release. The change is in the shared library; no SQL objects change,
results are unchanged, and no REINDEX is required.
`ALTER EXTENSION pg_fts UPDATE TO '0.2.3'` after installing the new library.

- **Ranked `ORDER BY d <=> q LIMIT k` over a boolean AND/NOT query is much
  faster.** The 0.2.1 boolean-structure correctness fix pre-collected the entire
  exact `@@@` match set before the ranked scan filtered against it, which was
  slow on common terms (e.g. `year & hungary` top-10 took ~37 ms at 2M docs
  because the whole `year` posting list was materialized). The ranked scan now
  evaluates the query's boolean structure **lazily** during the WAND traversal
  (from which terms are present at each candidate), with no collect pass:
  `year & hungary` top-10 drops to ~1 ms at 2M (measured), and a near-universe
  NOT like `year & !hungary` from ~415 ms to ~42 ms. Results are byte-identical
  (the ground-truth ranked-parity test passes unchanged). Pure-OR / single-term
  queries were already on the fast path and are unchanged; phrase/NEAR/fuzzy/
  regex keep the exact-recheck path.

## 0.2.2

Bug-fix release. The fix is in the shared library; no SQL objects change.
`ALTER EXTENSION pg_fts UPDATE TO '0.2.2'` after installing the new library.

- **Phrase (`"a b c"`) and NEAR queries now enforce term adjacency on all query
  paths.** They previously degraded to AND (matching any document containing the
  terms, regardless of order/adjacency) on the primary `to_ftsdoc(regconfig,
  text)` path — e.g. `to_ftsdoc('english', body)` — because that analyzer did not
  store token positions; and the index candidate path did not request the heap
  recheck that would have enforced adjacency, so non-adjacent documents leaked
  through `@@@`, the bitmap scan, and the ranked `<=>` scan alike. Now: the
  config analyzer stores positions; `@@@`/bitmap enforce adjacency via the
  executor recheck; and the ranked `<=>` scan and `fts_count()` recheck the exact
  match set against the heap document (`bm25_recheck_exact`). Phrase / NEAR /
  boolean ranking is exact on all paths.
- No REINDEX required (bm25 on-disk format unchanged). Phrase correctness on a
  *stored* `ftsdoc` column populated by the old analyzer requires re-analyzing
  those rows; expression indexes on `to_ftsdoc(...)` are correct immediately.
- Known limitation (documented): ranked `<=>` over fuzzy/prefix/regex returns a
  correct *subset* of the `@@@` matches (never a wrong document, but may be
  incomplete, since the ranked scan builds cursors from the literal term). Use
  `@@@` for exhaustive fuzzy/prefix/regex retrieval.

## 0.2.1

Bug-fix release. The fix is entirely in the shared library; no SQL objects
change and existing `fts` indexes need no REINDEX (on-disk format unchanged from
0.2.0). `ALTER EXTENSION pg_fts UPDATE TO '0.2.1'` after installing the new
library.

- **Ranked `<=>` scan now respects boolean AND/NOT/PHRASE structure.** The
  `ORDER BY d <=> q LIMIT k` ordering scan previously ranked the term
  *disjunction* (it flattened the query to its terms) and never intersected with
  the boolean match set that `@@@` uses, so AND/NOT/PHRASE queries could return
  documents that fail `@@@` — e.g. `a & !b` ranked documents that *contain* `b`.
  The ranked scan now gates results by the exact `@@@` match set, so every row
  it returns satisfies `@@@`. `@@@` matching and pure-OR / single-term ranking
  were already correct and are unchanged.

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

Known performance position (see `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md`):
pg_fts is far faster than the built-in tsvector/GIN + `ts_rank`
stack on ranked retrieval (up to ~40×), but trails the specialist BM25
extensions (VectorChord-bm25, Timescale pg_textsearch) on raw ranked latency and
index size.  Closing that
gap is a posting-codec rewrite tracked in `ROADMAP.md`; 0.1.0 ships on its
distinguishing strengths — query-language breadth, index-native COUNT, and
MVCC/crash correctness — and will iterate on ranked performance.
