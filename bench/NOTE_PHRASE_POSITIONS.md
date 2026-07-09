# Phrase/NEAR positions: correctness gap in the regconfig analyzer

Status: **confirmed correctness bug in shipped 0.2.1**, root-caused directly
(the investigation agent set up the repro but did not finish; this note records
the verified finding).

## Symptom

Phrase and NEAR queries silently degrade to AND (conjunction) when the document
was produced by the **config-based analyzer** `to_ftsdoc(regconfig, text)` — the
primary, documented path (`to_ftsdoc('english', body)`). A `"a b"` phrase
matches any document containing both `a` and `b`, regardless of adjacency.

Measured (PG17, via the flake installcheck harness, direct operator on a plain
ftsdoc value — no index involved):

| doc (analyzer) | query | result | correct? |
|---|---|---|---|
| `to_ftsdoc('simple'::regconfig, 'quick red slow brown')` | `"quick brown"` | **t** | ✗ should be f (not adjacent) |
| `to_ftsdoc('quick red slow brown')` (simple/text analyzer) | `"quick brown"` | **f** | ✓ correct |
| `to_ftsdoc('quick brown fox')` (simple/text analyzer) | `"quick brown"` | t | ✓ correct |

So: the `to_ftsdoc(text)` "simple" analyzer enforces phrase adjacency correctly;
the `to_ftsdoc(regconfig, text)` analyzer does not.

## Root cause

`phrase_step` (pg_fts_match.c:~92) is correct — it checks `0 < p - L <= distance`
against the two terms' position lists. But it only runs when both terms carry
positions; otherwise it explicitly falls back to presence-only AND
(pg_fts_match.c:~105, "recall preserved, precision degraded"). Whether a term
carries positions is gated by `FTS_DOC_HAS_POS(doc)` = `flags & FTS_DOCF_POSITIONS`
(pg_fts.h:71), read in `term_positions` (pg_fts_match.c:~72).

- The **text/simple** analyzer `fts_analyze_text` records a position per token
  and sets `doc->flags = FTS_DOCF_POSITIONS` (pg_fts_analyze.c:187) + allocates a
  positions region (pg_fts_analyze.c:183). → positions present → adjacency
  enforced.
- The **regconfig** analyzer in pg_fts_tsanalyze.c allocates only
  `HDRSIZE + entries + lexbytes` (NO positions region) and sets `doc->flags = 0`
  (pg_fts_tsanalyze.c:72,112). It never stores token positions even though the
  tsearch parser (`parsetext`) provides `ParsedWord.pos`. → positions absent →
  `term_positions` returns pos=NULL → `phrase_step` degrades to AND.

`ftsdoc_recv` also builds position-free docs (pg_fts_doc.c:166) — same
degradation on the binary wire path (lower impact; the recv comment already
notes it).

## Impact

High-visibility: every README/doc example uses `to_ftsdoc('english', body)`, and
phrase (`"a b c"`) / NEAR are advertised features. On that path they return
wrong (over-broad) results. This affects ALL query paths equally (direct `@@@`,
bitmap scan, ranked `<=>`) because they all evaluate phrases via
`fts_doc_matches` on the heap ftsdoc — it is NOT an index or ranked-scan issue
(the ranked-scan boolean-filter fix in 0.2.1 is orthogonal and correct).

## Fix

Make the regconfig analyzer store positions exactly like the text analyzer does:
in pg_fts_tsanalyze.c, size the doc to include a positions region
(one uint32 per token, per the `ParsedWord.pos` the tsearch parser already
yields), write the per-term ascending positions, and set
`doc->flags = FTS_DOCF_POSITIONS`. The on-disk/wire format is already versioned
(FTS_DOC_VERSION = 2, positions "optionally stored") and `phrase_step` +
`term_positions` already consume positions when present — so this is an analyzer
change, no format-version bump, no change to matching logic.

Watch-fors:
- Increases the ftsdoc size (a positions array). This is the heap column, not
  the bm25 index (the index stores no positions regardless), so index size is
  unaffected; the heap ftsdoc column grows. Acceptable and necessary for
  correct phrases; a future `WITH (positions=off)` could opt out for
  phrase-free workloads (heap-side only, tracked separately).
- `ftsdoc_recv` should either also store positions or the recv path stays
  presence-only (documented) — decide for consistency.
- Add a regression test: phrase adjacency on the **regconfig** analyzer (the
  existing phrase tests may all use the text analyzer and thus pass while the
  real path is broken — verify and add a regconfig case).

Priority: correctness bug on the primary documented path — fix before further
performance work. Likely a 0.2.2.
