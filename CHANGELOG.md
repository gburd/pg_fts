# Changelog

All notable changes to pg_fts are documented here.

## Unreleased

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

Known performance position (see `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md` and
`HANDOFF.md`): pg_fts is far faster than the built-in tsvector/GIN + `ts_rank`
stack on ranked retrieval (up to ~40×), but trails the specialist BM25
extensions (VectorChord-bm25, Timescale pg_textsearch) on raw ranked latency and
index size, because it stores positional postings for phrase/NEAR.  Closing that
gap is a posting-codec rewrite tracked in `ROADMAP.md`; 0.1.0 ships on its
distinguishing strengths — query-language breadth, index-native COUNT, and
MVCC/crash correctness — and will iterate on ranked performance.
