# PLAN — ROADMAP item 5: heap-side `positions=off` for `ftsdoc`

Status: **NO-GO as scoped.** Read-only architecture analysis, no code changed.
Date: 2026-09 (analysis of HEAD; `pg_fts.so` mtime 2026-08-28, extension 1.5.10).

---

## Summary

ROADMAP item 5 (`ROADMAP.md:193-223`) proposes an option to omit token positions
from the heap `ftsdoc` value for phrase-free workloads, for a smaller heap column
and faster build/insert/merge. The ROADMAP already narrows it correctly: heap-side
only, does not shrink the bm25 index, and gated on the `phrase_step()`
presence-only fallback (`pg_fts_match.c:174-182`) not becoming a live
silent-wrong-answer path.

Three findings emerged from tracing the code. In descending order of importance:

1. **The premise that "positionless docs are currently unreachable" is FALSE.**
   The ROADMAP asserts positionless `ftsdoc` values cannot be constructed
   (`ROADMAP.md:207-215`). Three live producers construct them today, all in
   shipped SQL-visible API, and two are already pinned by regression tests that
   *record the wrong answer as expected output*:
   - `to_ftsdoc(tsvector)` on any tsvector with a positionless entry
     (`pg_fts_tsanalyze.c:264-272`) — `strip(to_tsvector(...))` is the obvious
     case, tested at `sql/pg_fts.sql:92` and `sql/pg_fts.sql:2678`.
   - The canonical `ftsdoc` literal grammar with `tf` but no `@positions`
     (`pg_fts_doc.c:431-436` accepts "positions for every term or none"), tested
     at `sql/pg_fts.sql:2800-2801` with **expected output `t` for a
     non-adjacent phrase** (`expected/pg_fts.out:5423-5431`).
   - `ftsdoc || ftsdoc` when either side is positionless
     (`pg_fts_doc.c:904`).
   The `nopos_*` assertions at `sql/pg_fts.sql:2958-2961` pin only the
   *raw-text-cast* path (`'bravo alpha'::ftsdoc`), where the analyzer synthesizes
   positions. They do not cover the three paths above. So the silent-wrong-answer
   path is **live in HEAD**, not dormant.

2. **The safety work is therefore independent of item 5 and should ship
   regardless.** This is the actionable outcome of this analysis. It is a small,
   self-contained correctness fix, and it does not need the option to exist.

3. **The size benefit does not justify the option.** Positions cost
   `4 × doclen` bytes. Against realistic docs the heap `ftsdoc` shrinks 16%
   (short doc) to 41% (long repetitive doc) raw — but `ftsdoc` is
   `STORAGE = extended` (`pg_fts--1.5.10.sql:33-40`), so the on-disk saving is
   the *compressed* delta, and there are two large structural offsets that
   erase most of the value: the option removes the only adjacency source for
   the DEFAULT index (index `positions=off`), and it disables field-zone
   (`term:A`) filtering, which lives exclusively in position label bits.

---

## Recommendation

**No-go on the option. Go on the safety fix, unbundled.**

Do, now, as a standalone correctness change:

- **S1.** Turn the `phrase_step()` presence-only fallback
  (`pg_fts_match.c:174-182`) into a hard `ERROR`. It is reachable today via
  three shipped code paths. Details and error text below.
- **S2.** Fix the three regression assertions that currently pin the wrong
  answer as expected (`sql/pg_fts.sql:2800-2801`, and the `strip()` case's
  implicit coverage), and extend the `nopos_` block to cover all three
  producers, not just the raw-text cast.

Do **not** do, absent a field report:

- The `positions=off` option itself, in any of the four surface forms evaluated
  below. The measured raw saving (16–41%) is modest, TOAST compression already
  captures a similar fraction, and the capability cost (phrase on a default
  index; all field-zone queries) is large and silent.

If a field report ever demands it (a positionless-by-construction ingest at
scale where heap size is the binding constraint), the option surface is
`to_ftsdoc_nopos(regconfig, text)` — a distinct function, reasoning in
"Option surface" below — and it must land **after** S1, never before or with it.

---

## Consumers of positions

Exhaustive trace of `FTS_DOCF_POSITIONS` / `FTS_DOC_HAS_POS` producers and
consumers.

### Producers (who sets the flag)

| Path | Site | Sets positions? |
|---|---|---|
| `fts_doc_build()` (single assembler) | `pg_fts_doc.c:197` | `has_pos` param |
| default text analyzer | `pg_fts_analyze.c:287` | **always** |
| ts-config analyzer (`to_ftsdoc(cfg,text)`) | `pg_fts_tsanalyze.c:143` | **always** |
| ts-config analyzer, nterms==0 | `pg_fts_tsanalyze.c:92-93` | no (empty doc, vacuously safe) |
| `ftsdoc_in` canonical literal | `pg_fts_doc.c:378` / `:451` | **only if `@` given** |
| `ftsdoc_in` raw-text fallback | `pg_fts_doc.c:463` → analyzer | always (synthesized) |
| `ftsdoc_recv` (binary/pg_dump -Fc) | `pg_fts_doc.c:568`, `:625` | wire `has_pos` byte; v2 msg ⇒ 0 |
| `to_ftsdoc(tsvector)` | `pg_fts_tsanalyze.c:264-272`, `:307` | **all-or-nothing; 0 if ANY entry positionless** |
| `ftsdoc \|\| ftsdoc` | `pg_fts_doc.c:904` | `HAS_POS(a) && HAS_POS(b)` |
| `setftsweight()` | `pg_fts_doc.c:866` | preserves; no-op on positionless |

So: three live SQL-reachable producers of positionless docs
(`ftsdoc_recv` v2 is a fourth, restore-only).

### Consumers that BREAK or silently degrade without positions

**Silent wrong answer (severity: high)**

- **Phrase** — `phrase_step()` `pg_fts_match.c:174-182`. If either side's
  `pos == NULL`, returns `left.present && right.present`, i.e. a conjunction
  reported as a phrase match. Comment: "recall preserved, precision degraded".
- **NEAR** — same site. `NEAR(a b, k)` desugars to `FTS_OP_PHRASE` with
  `distance = k` (`pg_fts_query.c:484`), so NEAR shares the exact defect. Bare
  `"a b"` desugars to `PHRASE(1)` (`pg_fts_query.c:405`).

**Silent precision loss, distinct from the above (severity: high, and NOT in
the ROADMAP's framing)**

- **Field-zone / weight filtering (`wmask`)** — `pg_fts_match.c:88-95`. Weight
  labels live in the *top two bits of each position word*
  (`pg_fts.h:143-150`). With no positions there is nowhere to store a label, so
  `term_positions()` treats every occurrence as label D and sets
  `v.present = (wmask & 1u) != 0`. Consequence: on a positionless doc,
  `term:A` matches **nothing** and `term:D` matches **everything containing the
  term**. Silent, and the failure mode differs per query. `setftsweight()`
  already documents the corollary — it returns a positionless doc unchanged
  (`pg_fts_doc.c:866`), so labeling is a no-op there.
- **`ftsdoc || ftsdoc` multi-field construction** — `pg_fts_doc.c:904`,
  `:920-924`. The documented multi-field idiom
  (`to_ftsdoc('english',subject,'A') || to_ftsdoc('english',body,'C')`,
  `pg_fts_doc.c:886-897`) collapses to a positionless doc if EITHER side lacks
  positions, silently destroying every zone label in the result — including the
  labels the other side legitimately had. A heap `positions=off` on one field
  would silently un-zone the whole concatenation.

**Already-correct fallbacks (no action needed, listed for completeness)**

- **Index build / insert / merge** — `pg_fts_am.c:641`, `:5194`, `:5538`,
  `:385-407`. Guarded by `bs->want_positions && FTS_DOC_HAS_POS(doc)`; a
  positionless doc records `poscnt = 0` and the block writer drops the whole
  block's positions (`pg_fts_am.c:1697-1707`). Correct, and this is where the
  option's claimed build/insert speedup would come from.
- **Index-native positional phrase** — `bm25_phrase_eval_seg()`
  `pg_fts_am_scan.c:1810-1814` returns `BM25_POSLOOKUP_NOPOS` and the caller
  falls back to AND + heap recheck. Correct — but the recheck lands in
  `fts_doc_matches` → `phrase_step`, so it inherits defect #1 above. This is
  the composition the ROADMAP flagged (`ROADMAP.md:198-203`) and it is the
  reason S1 must be an error rather than a warning.
- **Text output / binary send** — `pg_fts_doc.c:502`, `:637-661`. Both branch on
  `FTS_DOC_HAS_POS`; a positionless doc round-trips as `'term':tf` with no `@`.
- **Structural validator** — `pg_fts_doc.c:77` / `pg_fts_docvalid.h:127-146`.
  Position checks are inside `if (flags & FTS_DV_FLAG_POSITIONS)`; positionless
  images validate fine.

**Genuinely position-independent (verified, no impact)**

- BM25 scoring, all variants — `pg_fts_rank.c:147` (`e->tf`), `:128`
  (`doc->doclen`), BM25F `:436-443`. Reads `tf` and `doclen` from the entry
  array and header only.
- Term lookup / prefix / fuzzy / regex — `pg_fts_doc.c:684`, `:717`, `:762`,
  `:813`. Entry-array and lexeme-region only.
- `ftsdoc_length()` — `pg_fts_doc.c:673`, reads `doc->doclen`.
- **`highlight()` / `snippet()`** — `pg_fts_aux.c`. Verified position-free: both
  re-tokenize the ORIGINAL TEXT (`tokenize_and_mark`, `pg_fts_aux.c:62-96`) and
  match folded tokens against query term text (`query_has_term`, `:37-51`).
  They never touch an `ftsdoc`. **The task brief listed highlight/snippet as a
  suspected consumer; they are not.**
- `bm25_recheck_exact()` — `pg_fts_am_scan.c:2345`. Re-derives the doc from the
  heap tuple and calls `fts_doc_matches`, so it inherits defect #1 but adds no
  independent position dependency. Note this is the *ranked* and *count* path,
  which has no executor recheck — so a wrong `phrase_step` answer here is
  returned to the user with no further filter.

### One more interaction worth recording

Prefix-in-phrase (`"quick bro*"`) is **already** presence-only:
`term_positions()` returns no positions for `FTS_QF_PREFIX`
(`pg_fts_match.c:65-70`, comment "phrase-with-prefix is not tracked
positionally"), and the parser does accept a prefix term inside `"..."` and
`NEAR(...)` (`pg_fts_query.c:403`, `:441`). So `phrase_step` already takes its
degrading branch for prefix-in-phrase on a *fully positioned* doc. There is no
regression coverage for this (`grep '"[a-z]* [a-z]*\*"' sql/pg_fts.sql` → no
matches). **This is a pre-existing latent precision bug independent of item 5,
and it constrains S1's design** — see the Safety mechanism section, because a
blanket error in `phrase_step` would turn `"quick bro*"` from a
silently-imprecise answer into a hard failure, which may not be the desired
user-visible behaviour. Treat it as a separate decision.

---

## Option surface

The heap `ftsdoc` is produced by a function call, not by index DDL, so an index
`WITH (...)` reloption cannot reach it — correctly noted in the ROADMAP. Four
candidates, evaluated:

| Candidate | Verdict |
|---|---|
| **Distinct function** `to_ftsdoc_nopos(regconfig, text)` | **Recommended, if ever built.** |
| GUC `pg_fts.heap_positions` | Reject. |
| Typmod `ftsdoc(nopos)` | Reject. |
| Extra argument `to_ftsdoc(cfg, text, positions => false)` | Reject. |

**Distinct function — why it wins.** The decisive constraint is expression
indexes, which this project's own benchmarks use
(`ROADMAP.md:52-53`: `ORDER BY to_ftsdoc(body) <=> q`). An expression index
stores the function OID in `pg_index.indexprs`; `bm25_recheck_exact()`
re-evaluates that expression per candidate via `FormIndexDatum`
(`pg_fts_am_scan.c:2389`). A distinct function OID makes the choice part of the
index definition — immutable, dumped correctly by `pg_dump`, and guaranteed to
produce the same shape at build time and at recheck time. It also composes with
the existing `to_ftsdoc` overload set (`pg_fts--1.5.10.sql:80,93,102,382`)
without touching any existing signature, so no upgrade-script surgery.

**GUC — why it fails.** Fatal, not merely awkward: `to_ftsdoc` is declared
`IMMUTABLE` (`pg_fts--1.5.10.sql:80-91`). A GUC-dependent result makes it a
liar, and an expression index over it becomes silently corrupt the moment the
GUC differs between the session that built the index and the session that
rechecks. A stored generated column would take the build-time GUC and never
match. Non-starter.

**Typmod — why it fails.** A typmod on `ftsdoc` describes the *column*, but
positions are decided by the *producing function*, which never sees the target
typmod in an `INSERT ... SELECT to_ftsdoc(...)`. It would require a
typmod-coercion cast that strips positions after the fact — strictly more code
than the distinct function, for a worse guarantee, and it would silently strip
zone labels on assignment.

**Extra argument — why it fails.** A `boolean` argument keeps the same function
name, so `IMMUTABLE` is preserved and expression indexes are safe — this one is
defensible. It loses to the distinct function only on two counts: it needs a new
overload anyway (so the SQL-surface cost is identical), and `to_ftsdoc(cfg, text,
'A')` already exists for weights (`pg_fts--1.5.10.sql:382`), making a third
positional-argument overload set genuinely ambiguous to read. A named function is
self-documenting at the index-definition site, which is where a reader most needs
to see it.

---

## Safety mechanism

The task offers three options. Recommendation: **(c) primarily, (b) as its
user-visible form, and reject (a).**

### Reject (a) "require index `positions=on` before heap positions may be dropped"

Two reasons. First, it does not work: `fts_doc_matches` is reachable with **no
index at all** — the `@@@` operator is a plain sequential-scan-capable function
(`fts_match`, `pg_fts_match.c:246`; `pg_fts.h:8-11` documents seq-scan matching
as a first-class mode). There is no index whose reloption could be consulted.
Second, it couples a heap value's construction to a specific index's options,
which breaks the moment there are two indexes, or the index is dropped, or the
value is queried before an index exists.

### Adopt (c): make the `phrase_step` fallback an ERROR

`pg_fts_match.c:174-182` becomes an `ereport(ERROR)` instead of a
presence-only AND. This is the root-cause fix: every caller — seq scan
`fts_match`, the commutator `fts_match_commutator`, the bitmap heap recheck, the
ranked-scan `bm25_recheck_exact`, and the pending-list scan
(`pg_fts_am_scan.c:2251`) — routes through `fts_doc_matches` → `phrase_step`. One
guard covers all five. Erroring in each caller would be five times the diff and
would still miss any future caller.

**Why silent degradation is unacceptable here specifically.** Not a general
appeal to strictness — three concrete reasons:

1. It answers a **different question than the one asked** and labels the result
   as the answer. `WHERE d @@@ '"united states"'` returning every doc containing
   both words anywhere is not a slow phrase or a partial phrase — it is a
   conjunction with a phrase's name on it. A user has no way to detect it from
   the result.
2. The blast radius is worst on the paths with **no second filter**. The ranked
   `<=>` scan and `fts_count()` call `bm25_recheck_exact()` precisely because
   they have no executor recheck (`pg_fts_am_scan.c:2334-2336`). A wrong
   `phrase_step` answer there is final. `fts_count()` would return a
   confidently wrong number.
3. This project has already paid for exactly this failure mode once. The
   `FTS_DOC_POSITIONS` macro comment (`pg_fts.h:80-87`) records a bug where
   mis-computed alignment "pointed positions[] at garbage and silently degraded
   phrase/NEAR on every stored (column-resident) ftsdoc." The lesson taken there
   was that silent positional degradation is undetectable in practice. Same
   lesson applies.

### The error text, and where

Raised in `phrase_step()`, `pg_fts_match.c`, replacing lines 174-182:

```
ERROR:  phrase and NEAR queries require token positions
DETAIL:  This ftsdoc value carries no token positions, so word adjacency
         cannot be verified.
HINT:  Build the document with to_ftsdoc(), which stores positions.  A
       positionless ftsdoc comes from a stripped tsvector, a canonical
       literal written without '@' positions, or concatenating a
       positionless document.
```

`errcode`: `ERRCODE_FEATURE_NOT_SUPPORTED` (`0A000`). Rationale: the value is
structurally valid (`fts_doc_is_valid` passes), the request is simply not
answerable from it — not `ERRCODE_DATA_CORRUPTED`, which would wrongly imply the
heap is damaged and provoke a needless REINDEX, and not
`ERRCODE_INVALID_TEXT_REPRESENTATION`, which is `fts_doc_build`'s domain.

### (b) is the same thing, seen from outside

"A clear error for phrase/NEAR when neither side carries positions" is what (c)
produces at the user boundary. Implementing it as (c) — one site, at the point
of the impossible operation — is the smaller diff.

### The prefix-in-phrase constraint on S1

As noted above, `"quick bro*"` reaches `phrase_step` with `left.pos == NULL`
today on a fully-positioned doc (`pg_fts_match.c:65-70`). A blanket error would
break it. Two sub-options, decision needed:

- **S1a (recommended):** distinguish the two causes. Have `term_positions()`
  signal "positions withheld because this operand is prefix/fuzzy/regex" apart
  from "the document has none". Error only on the latter; keep the documented
  presence-only behaviour for the former. Costs one field on `MatchVal`.
- **S1b:** error on both. Smaller diff, but it converts a shipped (if imprecise)
  capability into a failure. Would need a compatibility note and probably a
  major-version bump.

Prefer S1a. It is the honest split: one case is a documented approximation of a
query the engine chose not to index positionally; the other is a
question the data cannot answer.

**Unverified:** whether any existing regression test depends on
prefix-in-phrase's current presence-only result. The grep found no such test,
but absence of a matching pattern is weaker than reading every phrase test.

---

## Size analysis

### Formula

From `fts_doc_build()` (`pg_fts_doc.c:181-183`) and the identical arithmetic in
both analyzers (`pg_fts_analyze.c:225-227`, `pg_fts_tsanalyze.c:127-131`):

```
posbase = MAXALIGN(FTS_DOC_HDRSIZE + nterms * sizeof(FtsTermEntry) + lexbytes)
size_on  = posbase + npos * 4
size_off = posbase
saving   = 4 * npos = 4 * doclen        (npos == sum(tf) == doclen)
```

Measured constants (compiled, `MAXIMUM_ALIGNOF == 8`):
`FTS_DOC_HDRSIZE = 20`, `sizeof(FtsTermEntry) = 16`.

So:

```
size_on(nterms, doclen, lexbytes) = MAXALIGN(20 + 16*nterms + lexbytes) + 4*doclen
saving_bytes = 4 * doclen
saving_frac  = 4*doclen / (MAXALIGN(20 + 16*nterms + lexbytes) + 4*doclen)
```

The saving scales with **total occurrences** (`doclen`), while the retained part
scales with **distinct terms** (`nterms`, at 16 B + lexeme each). So the fraction
saved rises with repetition — the opposite of the intuition that a "big
vocabulary" doc benefits most.

### Worked examples

Computed from the formula above:

| Document | nterms | doclen | lexbytes | on | off | saved | % |
|---|---|---|---|---|---|---|---|
| short, 50 tokens, 45 distinct, 6 B terms | 45 | 50 | 270 | 1216 | 1016 | 200 | **16.4%** |
| short, 50 tokens, all distinct | 50 | 50 | 300 | 1320 | 1120 | 200 | **15.2%** |
| long, 2000 tokens, 800 distinct, 7 B | 800 | 2000 | 5600 | 26424 | 18424 | 8000 | **30.3%** |
| long, 2000 tokens, 500 distinct, 7 B | 500 | 2000 | 3500 | 19520 | 11520 | 8000 | **41.0%** |
| wiki-ish, 5000 tokens, 1500 distinct | 1500 | 5000 | 10500 | 54520 | 34520 | 20000 | **36.7%** |

### The number that actually matters: after TOAST compression

`ftsdoc` is `STORAGE = extended` (`pg_fts--1.5.10.sql:33-40`), so anything past
the toast threshold is pglz-compressed and/or out-of-lined. The raw delta
overstates the disk saving. Modelled the same layouts as byte images and
compressed both (`zlib` level 6 as a pglz stand-in — pglz is weaker, so treat
these as an optimistic bound on the *compressed* saving):

| Document | raw saved | % raw | compressed saved | % compressed |
|---|---|---|---|---|
| 50 tok / 45 distinct | 200 | 16.4% | 91 | 16.9% |
| 2000 tok / 800 distinct | 8000 | 30.3% | 4608 | 38.0% |
| 2000 tok / 500 distinct | 8000 | 41.0% | 4411 | 48.2% |
| 5000 tok / 1500 distinct | 20000 | 36.7% | 9628 | 40.9% |

**Caveat, explicit:** these are synthetic layouts with random lexemes and
regular position strides — real English lexemes compress better (shared
prefixes) and real positions compress worse (irregular gaps). The *direction* is
robust (positions are a large, weakly-compressible fraction of a long doc); the
*digits* are a model, not a measurement. A real measurement is one query on the
existing 2.19M Wikipedia corpus:
`SELECT avg(pg_column_size(to_ftsdoc('english',content))) FROM docs TABLESAMPLE SYSTEM(1)`
versus the same over a positionless build. That has not been run.

### Reading the numbers

A 16% saving on short documents is not worth a new SQL function, a format
concern, and a capability cliff. The 30–41% band on long documents is real, but
the corpus that would benefit is exactly the corpus that most wants phrase search
(articles, email bodies, code), and this project already measured what losing
positional phrase costs there: 8,385 ms vs 229 ms ranked, 7,170 ms vs 132 ms for
an exact phrase `count(*)` (`ROADMAP.md:181-186`). Trading 30% of a heap column
for a 36× phrase regression is the wrong trade, and the trade is invisible at
`CREATE TABLE` time.

The precedent is this project's own: item 4a killed impact-ordered postings and
lazy per-entry decode by measuring first (`ROADMAP.md:130-150`), and item 4b
declined the lazy phrase gate on a bounded-ceiling argument
(`ROADMAP.md:187-192`). The same standard applied here says no.

---

## Compatibility

**Binary-compatible with existing values. No format version bump needed.**

Positionless `ftsdoc` is not a new format — it is an already-supported
configuration of format v3/v4:

- `flags` is a bitfield (`pg_fts.h:70-71`); `FTS_DOCF_POSITIONS` clear is
  already a legal, produced state (`pg_fts_doc.c:197`).
- Every reader branches on `FTS_DOC_HAS_POS`: output `pg_fts_doc.c:502`, send
  `:637`, `setftsweight` `:866`, concat `:904`, matcher
  `pg_fts_match.c:78`/`:94`, index build `pg_fts_am.c:641`/`:5194`/`:5538`.
- The validator's position checks are inside
  `if (flags & FTS_DV_FLAG_POSITIONS)` (`pg_fts_docvalid.h:127-146`), so a
  positionless image validates without change.
- `version` stays 4. A positionless v4 doc has no position words, so the v4
  distinction (label bits in position high bits, `pg_fts.h:69`) is vacuous — the
  same reasoning `pg_fts_docvalid.h:100-105` uses to accept v3 and v4 under one
  code path.

**Binary send/recv path (`has_pos`, as requested):**

- `ftsdoc_send` (`pg_fts_doc.c:637-661`) writes `has_pos` as one byte at
  `:644` and emits the positions region only when set. A positionless doc
  produces a shorter, well-formed v4 message.
- `ftsdoc_recv` (`pg_fts_doc.c:568`) reads the byte for `version >= 3` and
  defaults it to 0 for v2. It accepts `{4, 3, 2}` (`:561`).
- Round trip: `has_pos=0` → `fts_doc_build(..., has_pos=false, ...)` (`:625`)
  → `flags = 0` (`:197`). Exact.

**Existing stored columns still read correctly.** Nothing about existing values
changes; only a new producer would be added. No REINDEX, no `pg_dump`
incompatibility, no upgrade script beyond the new function's `CREATE FUNCTION`.

**One asymmetry worth flagging.** `ftsdoc_send` emits `doc->version`
verbatim (`:642`). A positionless doc built today still declares version 4, so
an *older* pg_fts (which accepts only 2 and 3) rejects the message. That is
pre-existing for all v4 docs and not introduced here, but it means "positionless
implies downgrade-safe" is false — the version field, not the flags, gates
downgrade.

---

## Test plan

Ordered by what each test protects. The S1/S2 tests should ship whether or not
the option is ever built.

### For S1/S2 (the safety fix) — required

Add to `sql/pg_fts.sql`, extending the `nopos_` block at 2958-2961. Every
producer of a positionless doc gets an explicit phrase/NEAR assertion.

```sql
-- (1) canonical literal without '@' positions -- currently returns t (WRONG)
SELECT $$'brown':1 'quick':1$$::ftsdoc @@@ '"quick brown"'::ftsquery
  AS nopos_literal_phrase_errors;
SELECT $$'fox':1 'quick':1$$::ftsdoc @@@ 'NEAR(quick fox, 1)'::ftsquery
  AS nopos_literal_near_errors;

-- (2) stripped tsvector -- the to_ftsdoc(tsvector) all-or-nothing path
SELECT to_ftsdoc(strip(to_tsvector('simple','quick brown fox')))
       @@@ '"quick brown"'::ftsquery AS nopos_stripped_phrase_errors;

-- (3) concat with a positionless side (pg_fts_doc.c:904)
SELECT (to_ftsdoc('simple','alpha bravo')
        || $$'gamma':1$$::ftsdoc) @@@ '"alpha bravo"'::ftsquery
  AS nopos_concat_phrase_errors;
```

All four must produce the new ERROR. Cases (1) and (2) **change existing
expected output** — `expected/pg_fts.out:5423-5431` currently records `t` for a
non-adjacent phrase. Updating those two blocks is the visible proof that a wrong
answer was being pinned.

Non-phrase queries on the same positionless docs must keep working (the error is
scoped to adjacency, not to the value):

```sql
SELECT to_ftsdoc(strip(to_tsvector('simple','quick brown fox')))
       @@@ 'brown'::ftsquery AS nopos_plain_term_still_matches;         -- t
SELECT $$'brown':1 'quick':1$$::ftsdoc @@@ 'quick & brown'::ftsquery
  AS nopos_conjunction_still_matches;                                  -- t
SELECT $$'brown':1 'quick':1$$::ftsdoc @@@ 'quic*'::ftsquery
  AS nopos_prefix_still_matches;                                       -- t
```

Field-zone consumers, which no test currently covers on a positionless doc:

```sql
SELECT to_ftsdoc(strip(to_tsvector('simple','quick brown')))
       @@@ 'quick:A'::ftsquery AS nopos_zone_A_no_match;               -- f
SELECT to_ftsdoc(strip(to_tsvector('simple','quick brown')))
       @@@ 'quick:D'::ftsquery AS nopos_zone_D_matches;                -- t
SELECT setftsweight(strip(to_tsvector('simple','quick brown'))::ftsdoc,'A')
       @@@ 'quick:A'::ftsquery AS nopos_setweight_is_noop;             -- f
```

Prefix-in-phrase, currently untested, pinning whichever S1a/S1b behaviour is
chosen:

```sql
SELECT to_ftsdoc('simple','quick brown') @@@ '"quick bro*"'::ftsquery
  AS prefix_in_phrase_presence_only;   -- S1a: t (documented approximation)
SELECT to_ftsdoc('simple','brown quick') @@@ '"quick bro*"'::ftsquery
  AS prefix_in_phrase_reversed;        -- S1a: t -- the imprecision, pinned
```

Error reachability through every caller, not just the seq scan — this is what
proves the single guard covers all five paths:

```sql
-- bitmap heap recheck (index positions=off is the default)
CREATE TABLE npos_t (id serial, d ftsdoc);
INSERT INTO npos_t (d) VALUES (to_ftsdoc(strip(to_tsvector('simple','quick brown fox'))));
CREATE INDEX npos_i ON npos_t USING fts (d);
SET enable_seqscan = off;
SELECT count(*) FROM npos_t WHERE d @@@ '"quick brown"'::ftsquery;  -- ERROR
-- ranked path (bm25_recheck_exact, no executor recheck)
SELECT id FROM npos_t ORDER BY d <=> '"quick brown"'::ftsquery LIMIT 1;  -- ERROR
-- pending-list scan (query before any merge -- see sql/pg_fts.sql:2680)
RESET enable_seqscan;
-- commutator
SELECT '"quick brown"'::ftsquery @@@ to_ftsdoc(strip(to_tsvector('simple','quick brown fox')));  -- ERROR
DROP TABLE npos_t;
```

The pending-list case is the one most easily missed: `pg_fts_am_scan.c:2251`
calls `fts_doc_matches` on raw pending-page bytes, so it must be exercised
*before* `fts_merge` (the pattern at `sql/pg_fts.sql:2680-2684`).

### For the option, if ever built — additional

- `to_ftsdoc_nopos()` output has no `@` and `ftsdoc_length()` is unchanged
  (`doclen` is a header field, `pg_fts_doc.c:673`).
- Binary round-trip: `COPY BINARY` / `ftsdoc_send`→`recv` of a `_nopos` doc
  preserves `flags = 0` and `doclen`.
- Expression index over `to_ftsdoc_nopos(...)`: build, then a phrase query must
  ERROR identically at build-derived and recheck-derived docs — proving
  `bm25_recheck_exact`'s `FormIndexDatum` re-evaluation
  (`pg_fts_am_scan.c:2389`) produces the same positionless shape.
- `fts_doc_is_valid` coverage: add a positionless shape to the `dv` table in
  `sql/pg_fts.sql:2660-2691`, exercised through both the pending scan and the
  post-`fts_merge` segment path.
- Fuzz harness: `test/fuzz/fuzz_docvalid.c` already toggles
  `FTS_DV_FLAG_POSITIONS` (`:245`), so validator coverage exists.

---

## Open questions

1. **S1a vs S1b for prefix-in-phrase.** Is the current presence-only answer for
   `"quick bro*"` a documented feature to preserve, or an unnoticed bug to fix?
   The code comment (`pg_fts_match.c:67`) reads as deliberate; no test pins it.
   This is the only real design fork in the safety fix.
2. **Do the two wrong-answer regression assertions
   (`sql/pg_fts.sql:2800-2801`) predate the phrase work, or were they written
   knowing they pinned a conjunction as a phrase?** The surrounding comment
   ("degrades to plain AND ... so a non-adjacent phrase still matches") reads as
   fully aware. If intentional, S1 is a behaviour change needing a CHANGELOG
   entry and possibly a version bump, not just a bug fix.
3. **Is `to_ftsdoc(strip(...))` a real adoption path anyone uses?** It is the
   tsvector on-ramp (`pg_fts_tsanalyze.c:229-238`) and the most likely
   real-world source of a positionless doc. If users do this, they have silently
   wrong phrase results today, which raises S1's urgency from "cleanup" to
   "correctness release".
4. **Should the compressed-size model be replaced by a real measurement before
   this no-go is final?** One `pg_column_size` query on the existing 2.19M
   corpus would settle it. The recommendation does not hinge on it — the
   capability cost decides — but the project's stated norm is to measure.
5. **Unverified:** every claim here is from static reading; no build or SQL was
   run (no live PostgreSQL instance in this environment). The `expected/*.out`
   contents corroborate the two wrong-answer assertions and the `strip()`
   behaviour, but the concat-path positionless claim (`pg_fts_doc.c:904`) is
   read-only inference with no test exercising it.
