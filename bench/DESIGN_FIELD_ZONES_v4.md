# Design: field-targeted (weight-zone) search in pg_fts (v1.4.0, format v4)

Requested in `pg_fts-feature-field-targeted-search-2026-08-25.md`. Add
tsvector-style A/B/C/D weight labels so a single ftsdoc can carry field
provenance and a query term can restrict itself to a zone -- `subject:vacuum`
expressed as `to_ftsquery('english','vacuum:A')` over a document built from
`to_ftsdoc('english', subject, 'A') || to_ftsdoc('english', body, 'C')`.

## Key insight that avoids a re-index (revised: value-only labels + recheck)

Weight labels live ONLY in the ftsdoc VALUE (the heap column), encoded in the
top 2 bits of each `uint32` position word:

    position word (uint32):  [ label:2 | ordinal:30 ]
    label 0 = D (default/unlabeled)   1 = C   2 = B   3 = A   (tsvector D<C<B<A)

The on-disk INDEX posting format is UNCHANGED (still v3): posting positions carry
only the ordinal (the build masks the label off).  A field-restricted query term
(`term:A`) is answered like fuzzy/regex/NOT already are -- the index finds the
candidate docids by term, and the heap ftsdoc (which HAS the labels) applies the
label filter in the recheck.  So:

  * **No index format change, no REINDEX.** Existing indexes keep working; a
    query without `:label` behaves exactly as before.  `ALTER EXTENSION pg_fts
    UPDATE TO '1.4.0'` is sufficient.
  * A field-restricted query requires the ROW's ftsdoc to carry labels, i.e. the
    table's ftsdoc must be (re)built from labelled `to_ftsdoc(...,weight)||...`
    documents -- opt-in per table, not a global reindex.  On an unlabelled
    (v3) ftsdoc every position is label D, so `term:D` matches and `term:A`
    (etc.) simply doesn't -- correct, no error.
  * Only the ftsdoc VALUE version bumps v3 -> v4 (label bit in position words);
    the index/metapage version stays 3.  ftsdoc_recv/out read v2/v3/v4.

A future optimization can push labels into the positions posting column for a
fully index-native filter (a real index format change, its own release); this
release keeps the index format stable and filters via the heap recheck, which
is correct and needs no reindex.

## Format versioning

- ftsdoc VALUE: `FTS_DOC_VERSION` 3 -> 4.  A v4 header is byte-identical to v3
  except a new flag `FTS_DOCF_WEIGHTS (0x0002)` set when any position carries a
  non-D label.  `ftsdoc_recv`/`ftsdoc_out` read both: a v3 value (or a v4 value
  without the flag) has all-D labels.  `ftsdoc_out` renders `'term':1A,3C` only
  when labels are present (v3 render `'term':1,3` is preserved exactly when not).
- Index (metapage) `BM25_VERSION` 3 -> 4.  A v4 metapage is identical to v3; the
  bump only records the writer's capability.  A v3 metapage (older index) is
  read as "positions, if present, have label D everywhere".  bm25_read_meta
  accepts version 3 and 4; write path stamps 4.  No segment/page byte layout
  changes -- the label rides in position words that already existed.

## API surface (SQL)

1. `to_ftsdoc(regconfig, text, weight "char")` -- analyze `text` and tag every
   token position with `weight` in {A,B,C,D}.  (2-arg forms unchanged = all D.)
2. `setftsweight(ftsdoc, "char")` -- relabel every position of an existing
   ftsdoc (mirrors `setweight(tsvector,"char")`).
3. `ftsdoc || ftsdoc` -> ftsdoc -- concatenate, re-basing the right operand's
   position ordinals after the left's doclen and preserving each side's labels.
   New CREATE OPERATOR `||` + `ftsdoc_concat(ftsdoc,ftsdoc)`.
4. Query syntax `term:A`, `term:AB`, `term:{A,B}` -- restrict a plain/prefix/
   fuzzy/regex term to positions whose label is in the set.  Lexer: after a
   term, an optional `:` followed by a run of `[ABCDabcd]` sets a 4-bit label
   mask on the query item (new `FTS_QF_WEIGHTED` flag + `weightmask` in the
   item; the item struct has a spare field).  `to_tsquery`-compatible.

## Matching semantics (tsquery-identical)

- A query term with a weight mask matches a document iff the term occurs at
  >= 1 position whose label is IN the mask.  Requires the document/index to
  carry positions; on a positions-off index a weighted query term ERRORs with a
  clear hint (build `WITH (positions=on)` for field-restricted search) rather
  than silently ignoring the label.
- **BM25 df/tf stay document-level** (as the reporter asked): the label is a
  match-time position filter only, exactly like tsquery weight matching.  A
  zone filter changes WHICH docs match, not how a matching doc scores.
- Heap recheck (`@@@` on a value; lossy fuzzy/regex/NOT recheck) applies the
  SAME label filter as the index, so index and recheck never diverge.

## Where the label is read/written (implementation map)

- Analyzer (`pg_fts_tsanalyze.c` / `pg_fts_doc.c`): OR the label into each
  position word when building `positions[]`.
- Value concat (`pg_fts_doc.c`): merge two docs, re-base right ordinals
  (mask off label, add left doclen, OR label back).
- Index build (`pg_fts_am.c`): positions already flow value->posting; the label
  bits ride along unchanged (they are part of the uint32).  The block FOR-pack
  of positions must pack the FULL uint32 (label + ordinal), and the delta-coding
  of positions must delta the ORDINAL only (mask the label out before delta,
  OR it back after) -- otherwise labels perturb the deltas and inflate the
  column.  This is the one subtle codec change.
- Match (`pg_fts_am_scan.c` positions decode + `pg_fts_doc.c` fts_doc_matches):
  when an item has a weight mask, a position satisfies it iff
  `(1 << label(pos)) & mask`.
- Query parse (`pg_fts_query.c`): lex `:ABCD`, set item weightmask; render it.

## Testing / qualification

- old-format TAP test: build a v3 index (positions on) with the 1.3.2 build,
  `ALTER EXTENSION UPDATE`, then query it with the v4 build -- unrestricted
  queries identical; a weighted query treats all positions as D.
- SQL regression: to_ftsdoc(...,weight), setftsweight, ||, term:A/AB, mismatch
  (weighted term on positions-off index -> error), BM25 df document-level
  invariance, index-vs-recheck parity, phrase+weight interaction.
- EC2 scale: 2.19M labeled corpus (subject A / body C), field-restricted counts
  + ranked exactness; positions-column size delta from the label bits (should be
  ~0 -- the ordinals are unchanged, labels are free high bits).
- Full gate + fuzz (codec teeth must still hold with label bits) + coverage.
