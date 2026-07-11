# Fixing the phrase/NEAR count cliff — a positional bm25 index (design) + a shipped interim correctness fix

Follows bench/RESULTS_ANDOPT.md (the ~232 s phrase-count cliff at 2M) and
bench/NOTE_PHRASE_POSITIONS.md (the 0.2.2 analyzer positions fix).  This note:

1. reports a **cheap, correct, measured interim fix that is staged now** — but it
   is NOT the fix the cliff-benchmark's expression index needs; it fixes a
   *separate, shipped correctness bug* and it collapses the cliff only for the
   **stored-ftsdoc-column** index shape;
2. designs the real fix — **token positions in the bm25 postings** — with the
   P1-failure-mode checks (fts_vacuum reclaim, build alloc, lazy decode) up front;
3. frames the size tradeoff, the reloption scope, and a recommended sequencing.

All measurements below are local (Nix `pgWith` temp cluster, PG 17.10, warm
cache, `shared_buffers=2GB`, `jit=off`) at a **200k-doc repro** that reproduces
the cliff mechanism (a common two-word phrase whose AND-set ≫ phrase-set).  The
machine was under variable load, so absolute ms drift run-to-run; the **ratios
and the correctness results are the load-independent facts.**  `installcheck-pg17`
and `installcheck-pg18` are **EXIT 0** with the staged change.

---

## 0. TL;DR

- The cliff is `bm25_recheck_exact` (pg_fts_am_scan.c:1562) fetching **every**
  member of the AND-set from the heap and, for the documented **expression
  index** `USING fts (to_ftsdoc('english', body))`, calling `FormIndexDatum`,
  which **re-runs `to_ftsdoc` — a full re-tokenization of the whole body** — per
  candidate.  411k candidates × (random heap fetch + detoast + re-tokenize +
  phrase check) ≈ 232 s at 2M.
- **The dominant cost is the per-candidate re-analysis, not the raw phrase
  check.**  Measured on the 200k repro (expression index): AND count ~50–150 ms,
  phrase count **~5.5–10 s** — a **50–120× cliff**, matching the 2M shape.
- **Interim fix (STAGED, measured, shippable):** while root-causing, I found a
  **real correctness bug in shipped v0.2.3** — `FTS_DOC_POSITIONS` used
  `MAXALIGN()` of an *absolute pointer*, which mismatches the analyzer's
  offset-based layout whenever a detoasted / heap-read ftsdoc lands at a
  non-MAXALIGN'd address.  Result: **phrase/NEAR silently degraded to AND on
  every stored (column-resident) ftsdoc.**  The one-line fix restores
  correctness AND, because a stored-column recheck reads the column instead of
  re-tokenizing, drops the stored-column phrase cliff by **~20–57×** (repro:
  ~493 ms vs the expression index's ~9.9 s, both returning the correct 80000).
  It does **nothing** for the expression index (which never stores an ftsdoc).
- **Real fix (DESIGN, not built):** store per-(term,doc) token positions as a
  **4th, lazily-decoded FOR column** in the posting blocks, bump `BM25_VERSION`
  2→3, evaluate phrase/NEAR directly from postings (reuse `phrase_step`), and set
  `need_recheck=false` for phrase.  This takes phrase count/match to posting-scan
  speed with **zero heap access**, for both index shapes.  It roughly doubles
  posting bytes, so it is gated behind a `WITH (positions=...)` reloption.

---

## 1. The cliff, reproduced and dissected

Repro corpus: 200k docs, each ~40 filler tokens; 40% contain the adjacent
phrase "united states", another 40% contain both words but non-adjacent (the
AND-set is 160k, the phrase-set is 80k).  Expression index
`USING fts (to_ftsdoc('english', body))`, `fts_vacuum`'d to one segment.

| query | median ms | rows |
|---|---:|---:|
| `count(*) … @@@ to_ftsquery('english','united & states')` (AND) | ~50–150 | 160000 |
| `count(*) … @@@ to_ftsquery('english','"united states"')` (phrase) | **~5500–9900** | 80000 |
| `fts_count(idx, '"united states"')` | **~5300** | 80000 |

Ratio ≈ **50–120×**, the same shape as the 2M `232 000 ms` vs `0.24 ms`.

### Why it is slow — the exact code path

`bm25_collect_matches` (pg_fts_am_scan.c:1310) evaluates `FTS_OP_PHRASE` as
plain AND (`bm25_eval_query`, :680 — "PHRASE is treated as AND … the bitmap heap
recheck (@@@) enforces adjacency"), and sets `need_recheck=true` for phrase
(:1461).  The ranked `<=>` path (:2992) and `fts_count`/count-pushdown
(bm25_count_visible, :3198) have no executor recheck, so they call
`bm25_recheck_exact` (:1562), which for each of the 160k AND-set TIDs:

1. `table_index_fetch_tuple` — a **random single-tuple heap fetch**;
2. `FormIndexDatum(indexInfo, slot, …)` — **evaluates the index expression**;
3. `PG_DETOAST_DATUM` + `fts_doc_matches` — the actual phrase check.

For the **expression** index the expression *is* `to_ftsdoc('english', body)`, so
step 2 **re-tokenizes the entire body through the tsearch parser+stemmer** —
pure waste, since the positions the phrase check wants were already computed at
index-build time (and thrown away, see §3).

### Where the time goes (measured)

- A **bulk** `SELECT to_ftsdoc('english', body)` over the same 160k rows via a
  seqscan is **~20 ms** — batched, sequential.  So raw tokenization CPU is *not*
  the cliff.
- The cliff is **160k independent `table_index_fetch_tuple` random fetches +
  per-tuple `FormIndexDatum` + per-tuple executor state churn.**  Both the random
  heap access and the per-tuple re-analysis are structural to the recheck.

**Consequence for an "interim" fix on the expression index:** there is *nothing
stored to read instead of re-analyzing* — the ftsdoc for an expression index
exists only as positionless postings or must be recomputed.  Any correct recheck
must touch the heap once per candidate.  **No cheap interim fix cures the
expression-index cliff.**  Only positional postings (no recheck) do — that is
§3.

---

## 2. The interim fix (STAGED, measured) — a shipped correctness bug in the way

While instrumenting the recheck I compared the expression index against the
**stored-ftsdoc-column** shape `USING fts (d)` (an `ftsdoc` column populated by
`UPDATE t SET d = to_ftsdoc('english', body)`), where `FormIndexDatum` just
*reads the stored column* — no re-analysis.  That path returned **0 phrase
matches** where the correct answer is 80000.

### Root cause (bug present in pristine v0.2.3, confirmed by a clean build)

`FTS_DOC_POSITIONS(d)` (pg_fts.h) was:

```c
#define FTS_DOC_POSITIONS(d) \
    ((uint32 *) MAXALIGN((char *) FTS_DOC_LEXEMES(d) + (d)->lexbytes))
```

i.e. `MAXALIGN()` of an **absolute pointer**.  The analyzers lay the positions
region out at an **offset**: `posbase = MAXALIGN(HDRSIZE + nterms*sizeof(entry) +
lexbytes)` from the doc start (pg_fts_tsanalyze.c:130, pg_fts_analyze.c).  These
agree **only when the doc's base address is itself MAXALIGN'd**.  A freshly
`palloc`'d doc is; a **detoasted / heap-read** doc frequently is not, and then
`MAXALIGN(base+off) ≠ base+MAXALIGN(off)` — `FTS_DOC_POSITIONS` points a few
bytes off, `phrase_step` reads garbage positions, and phrase/NEAR silently
**degrade to AND** (or, as measured, to *nothing*) on every stored ftsdoc.

Why the test suite missed it: the existing phrase tests store only **short** docs
(`'the quick brown fox'`, 3–4 tokens) whose region happened to land aligned.  The
bug is **erratic in doc length** (repro table: 10 tokens=fail, 16=pass, 17=fail,
30=pass …) — classic misalignment.

### The fix (one accessor, offset-based)

```c
#define FTS_DOC_POSITIONS(d) \
    ((uint32 *) ((char *) (d) + \
                 MAXALIGN(FTS_DOC_HDRSIZE + \
                          (Size) (d)->nterms * sizeof(FtsTermEntry) + \
                          (d)->lexbytes)))
```

`d + MAXALIGN(offset)` — exactly the analyzer's layout, independent of `d`'s
absolute alignment.  **No format change, no version bump** (the on-disk bytes
were always correct; only the reader's pointer math was wrong).

### Measured effect (200k repro, fixed clean build)

| index shape | phrase count, before fix | after fix | correct count |
|---|---:|---:|:---:|
| stored-column `USING fts (d)` | **0 rows (WRONG)** | **80000 (correct)** | 80000 |
| stored-column phrase latency | (fast because wrong) | **~493 ms** | — |
| expression `USING fts (to_ftsdoc(body))` | 80000 (correct) | 80000 (unchanged) | 80000 |
| expression phrase latency | ~9900 ms | ~9900 ms (unchanged) | — |

So the interim fix:
- **fixes a real, shipped, silent wrong-results bug** for stored-column phrase/NEAR
  (`@@@`, bitmap, ranked, `fts_count`);
- as a side effect, gives the **stored-column shape a ~20× phrase-count speedup
  vs the expression cliff** (~493 ms vs ~9.9 s, both correct), because its
  recheck reads a column instead of re-tokenizing;
- **does not help the expression index** — the documented primary path and the
  shape the 2M benchmark used.

### Staged artifacts

- `pg_fts.h` — the accessor fix (11 insertions, 2 deletions).
- `sql/pg_fts.sql` + `expected/pg_fts.out` — a regression test (`phlong`): store
  8 docs long enough to trigger the misalignment, assert stored-column phrase
  adjacency returns exactly the adjacent ids and that the stored value agrees
  with a fresh re-analysis.  On pristine v0.2.3 this test returns `id=6` only and
  `stored_matches_fresh=f`; with the fix it returns `2,4,6,8` and `t`.
- `installcheck-pg17` / `installcheck-pg18`: **EXIT 0**.

**Shippable now** as a correctness patch (a 0.2.4).  It is byte-format-identical
(no on-disk change), so no REINDEX and no compatibility concern.  It is NOT the
cliff fix for the expression index — say so in the changelog.

---

## 3. The real fix — token positions in the bm25 postings (design)

The analyzer already computes per-term ascending positions and stores them in
the heap ftsdoc (`FTS_DOCF_POSITIONS`, pg_fts_tsanalyze.c / pg_fts_analyze.c).
The build callback (`bm25_build_callback`, pg_fts_am.c:317) reads
`entries[i].tf` and `doc->doclen` and **drops the positions** at `add_posting`.
The fix carries them into the postings so phrase adjacency is evaluated directly
from the posting lists — a real positional inverted index — with **zero heap
access and no recheck**.

### 3.1 On-disk format — a 4th, lazily-decoded per-block column (recommended)

Current block (pg_fts_am.h:150, written pg_fts_am.c:718): a `BM25BlockHdr` then
**three** FOR columns as Structure-of-Arrays — `docid-gaps | tf | doclen` — each
`[u8 width][packed bits]` (pg_fts_for.h).  `bm25_decode_term` (pg_fts_am.c:396)
already decodes them and — crucially — the WAND hot path uses `bm25_for_bytelen`
to **skip** the tf/doclen columns and `bm25_for_get` to random-access a single
value only for scored postings.  **That skip machinery is exactly what makes the
positions column affordable — mirror it.**

**Recommended: option (a) — a 4th per-block "positions blob" column**, appended
after the three existing FOR columns:

```
BM25BlockHdr { …, bytelen (now covers 4 columns), + posbytelen (new) }
  FOR(docid-gaps)   [width][bits]          <- unchanged
  FOR(tf)           [width][bits]          <- unchanged
  FOR(doclen)       [width][bits]          <- unchanged
  POSITIONS blob:                          <- new, variable-length
    FOR(pos-deltas)  [width][bits over Σtf values in this block]
```

Layout of the positions blob, per block of ≤128 postings:
- Each posting *i* has `tf[i]` positions.  The block's total position count is
  `Σ tf[i]` (already known — the tf column).  So **no per-posting offset table is
  needed on disk**: a reader that wants posting *i*'s positions decodes the tf
  column (it must anyway) and walks the prefix sum.  This avoids the P1 trap of a
  fat directory.
- Positions within one posting are ascending; **delta-code within a posting**
  (first position stored as-is, rest as gaps), reset the running delta at each
  posting boundary.  Then FOR-pack the whole block's delta stream as one column
  (one width byte for the block).  Deltas are tiny (a term's occurrences in a doc
  are usually spread by a handful of tokens), so this packs to a few bits each —
  the same reason gaps/tf pack well.
- `posbytelen` in the header lets a reader **skip the entire positions blob** in
  one add when it does not need positions (ranked/AND/count) — the same
  `bytelen`-skip pattern the code already trusts.

Why (a) over (b) a separate per-segment positions sidecar keyed by (term,docid):
a sidecar re-introduces exactly P1's failure modes (a second structure the
compactor and the size accounting must track, packed against a *different*
neighbourhood, materialized somewhere at build).  Option (a) keeps positions
**inline in the block they belong to**, so:
- the merge/vacuum re-decode already visits every posting of every block →
  carrying positions through is a local change to one decode + one write path
  (§3.3), not a new structure;
- FOR packs positions against the block's own postings (good locality);
- the lazy `bytelen`-skip already exists.

### 3.2 Lazy decode — NON-NEGOTIABLE (the P1/replan lesson)

Positions roughly double posting bytes (§4).  A plain BM25 ranked / AND / count
query must **not** pay to decode them.  The design keeps decode lazy at three
levels, mirroring the existing tf/doclen laziness:

1. **`bm25_decode_term` gains a `bool want_positions` (or a separate
   `bm25_decode_term_pos`).**  When false — every ranked/AND/count caller — it
   does `p += posbytelen` after the three FOR columns and never touches the blob.
   Bytes are still *read from the page* (they are interleaved in the block), but
   this is a pointer add, not a decode; the memcpy of the block into `blkbuf`
   already happens.  (If §4 shows the extra resident bytes hurt the WAND scan's
   memcpy, a follow-up can split positions onto their own posting sub-chain — but
   NOTE_FORMAT_V3_PROFILE showed decode is not the ranked bottleneck, so start
   inline and measure before splitting.)
2. **Only phrase/NEAR evaluation requests positions**, and only for the docids
   that survive the docid-intersection (§3.4) — not the whole posting list.
3. The scan-side hot loops (`bm25_topk_candidates_range`, the WAND cursors) are
   untouched; they never set `want_positions`.

Kill criterion for the format change (per the replan): a ranked/AND/count query
must not regress beyond noise (>3%) vs v0.2.3 at 2M.  If it does, the positions
column is not being skipped cleanly — fix the skip, do not ship.

### 3.3 Build + merge + vacuum — carry positions, keep the compactor working

The single most important P1 lesson (RESULTS_P1_P4, NOTE_SIZE_SPEED_REPLAN §2):
**a format the compactor does not understand is an automatic size regression.**
`fts_vacuum`/merge reclaim works because `bm25_read_segment_into`
(pg_fts_am.c:1058) **re-decodes** each term's postings and **re-adds** them via
the same `add_posting` → `bm25_write_postings` path that build uses.  So:

- **`BuildTerm`** (pg_fts_am.c:83) gains a positions store parallel to `tfs`:
  a flat `uint32 *positions` plus per-posting counts (== `tfs[i]`).  `add_posting`
  gains a `const uint32 *pos, int npos` argument.
- **`bm25_build_callback`** passes `FTS_DOC_TERMPOS(doc, &entries[i])` and
  `entries[i].tf` — the positions are *right there* in the ftsdoc it already
  detoasts.  (Uses the §2-fixed accessor — do the interim fix first or the build
  ingests garbage positions on stored-column indexes.)
- **`bm25_write_postings`** (pg_fts_am.c:718) writes the 4th column.  The block
  scratch buffer is currently `scratch[3 * (1 + (128*64+7)/8)]` — sized for
  exactly three ≤64-bit columns.  The positions blob is `Σtf` values, and
  **`Σtf` per 128-posting block is unbounded** (a block could hold 128 postings
  each with large tf).  **This is the build-alloc trap (P1's 1 GB `palloc`
  overflow, restated).**  Bound it: cap positions materialized per block, and if a
  single doc's tf for a term is pathological, either (i) cap stored positions per
  (term,doc) at a documented ceiling (tsearch itself caps at `MAXENTRYPOS`
  ≈ 16383) and fall back to recheck for that one posting, or (ii) size the scratch
  from the actual `Σtf` of the block with a `MemoryContextAllocHuge`-style guard —
  **never a fixed stack array that `Σtf` can overflow.**  Verify at 2M with a
  build that does not trip `MaxAllocSize`.
- **`bm25_read_segment_into`** decodes positions (`want_positions=true`) and
  passes them back through `add_posting`, so **merge and fts_vacuum carry
  positions and keep reclaiming.**  Add a test: build a positional index, delete
  rows, `fts_vacuum`, assert (a) size drops and (b) phrase still correct — the
  P1-reclaim gate.
- **`bm25_free_segment` / `bm25_free_chain`** need no change — positions live in
  the same posting pages already freed.

### 3.4 Phrase evaluation from postings (no heap, no recheck)

In `bm25_eval_query` (pg_fts_am_scan.c:634), `FTS_OP_PHRASE` currently collapses
to `tidset_and`.  Replace the phrase operator with a positional intersection:

1. For each phrase term, a positional posting lookup returns, per docid, the
   ascending position list (decode positions **only** for this term's postings).
2. Intersect the two operands on **docid** first (the existing `tidset_and`
   galloping intersection — cheap, selective).  Only for co-occurring docids do
   we look at positions.
3. For each surviving docid, run the existing **`phrase_step`** logic
   (pg_fts_match.c:92) on the two position lists: keep the docid iff some right
   position `p` has a left position `L` with `0 < p−L ≤ distance`.  Chain across a
   multi-word phrase exactly as `fts_doc_matches` does.  **`phrase_step` is reused
   verbatim** — it already operates on ascending `uint32` position arrays, which
   is precisely what the postings now yield.
4. Result is the exact phrase set → **`need_recheck=false`** for phrase (the
   recheck — the cliff — is gone).  `bm25_recheck_exact` stays only for
   fuzzy/regex/NOT-universe over-generation and for phrase over a **non-positional
   segment** (§6).

This makes phrase/NEAR count and match answerable at posting-scan speed (the
AND-count range), for **both** index shapes, with zero heap access — the stated
goal.

### 3.5 Format version + compatibility

Bump `BM25_VERSION` 2→3 (pg_fts_am.h:24).  The existing guard
(pg_fts_am.c:640) rejects a v2 index with
`errhint("REINDEX the index to rebuild it in the current format.")` — reuse it
unchanged.  A v2 index built by an older binary keeps working only after REINDEX;
document in the upgrade SQL.  (The heap ftsdoc `FTS_DOC_VERSION` is unaffected —
it already carries positions since 0.2.2; this bump is the *index* format only.)

---

## 4. Size impact + the reloption

Positions add one stored value per token occurrence (`Σ tf` = total tokens),
delta+FOR-coded.  Modeled against the existing three columns (NOTE_SIZE_SPEED_REPLAN
§1a): for a dense common term the current block is ~3.6 B/posting split
gaps 0.76 / tf 0.63 / doclen 2.01.  Positions add `tf` deltas per posting; for an
article corpus `tf` averages small but the *count* of positions equals total
tokens, so the positions column is on the order of the **whole current posting
size again** → **~1.8–2.2× posting bytes**, i.e. roughly **double the index**
(consistent with tsvector-with-positions vs without).  This is the opposite
direction from the size goal — state it honestly.

**Therefore: positions MUST be optional per index, via a reloption.**  pg_fts has
**no reloptions today** (`bm25_options` returns NULL — real work to add one; scope
it as part of this feature, not a freebie).  Proposed:

```
CREATE INDEX … USING fts (…) WITH (positions = on|off);
```

- `positions=off`: current v2-equivalent postings (no 4th column), small index,
  phrase/NEAR falls back to the **bounded** recheck (§6) or is rejected.
- `positions=on`: the v3 positional postings, phrase/NEAR at posting speed.

**Recommended default: `off`.**  Rationale: it preserves today's size and today's
ranked/AND/count latency for the majority who never phrase-search; phrase users
opt in knowing the ~2× size cost.  (An argument for `on`-by-default is that
phrase is an advertised feature and silently slow-by-default is a trap — but the
2× size hit on every index, including phrase-free ones, is the worse default
given pg_fts is already larger than vchord/pg_textsearch.)  Ship `off` default +
a loud doc note: "phrase/NEAR at index speed needs `WITH (positions=on)`."

NOTE the earlier NOTE_SIZE_SPEED_REPLAN's "positions-off is heap-side only" — that
was about the *heap ftsdoc* column.  **This reloption is about *index* postings**,
which is the opposite lever: index positions are what make phrase fast, and they
are what cost the ~2×.  The two are independent knobs.

---

## 5. Interaction with the P1–P4 size/latency story

- P1–P4 tried to make the index *smaller/faster* and regressed everything.  This
  change deliberately makes a **positional** index *bigger* (~2×) to kill a 232 s
  cliff — a different axis, and an honest trade: correctness+latency for phrase at
  the cost of size, **opt-in**, never forced on the size-sensitive workloads.
- It reuses P1's hard-won lessons as *gates*, not predictions: (a) the compactor
  must reclaim the new format — tested; (b) build must not trip `MaxAllocSize` —
  the `Σtf`-per-block bound in §3.3; (c) decode must be lazy — §3.2, mirroring the
  tf/doclen skip that already exists.
- It does **not** touch the WAND/MaxScore ranked scorers, the impact-ordering, or
  the tiered merge policy — the parts P1–P4 broke.  It adds one column and one
  operator evaluation path.

---

## 6. Fallback: positions off, or phrase over a non-positional segment

Keep `bm25_recheck_exact` for: fuzzy/regex/NOT-universe over-generation (unchanged),
and phrase/NEAR when the segment (or the whole index, `positions=off`) has no
positions.  But **bound it** so a phrase-over-a-nonpositional-segment is never
another 232 s cliff:

- **Read stored positions instead of re-analyzing where possible.**  For a
  **stored-ftsdoc-column** index the recheck's `FormIndexDatum` already just
  reads the column (post-§2-fix, correctly) — ~20× cheaper than re-analysis and
  correct.  For an **expression** index there is nothing stored, so the recheck
  must re-analyze; there is no cheaper correct option without positions.
- **Cap the recheck set for `@@@`/bitmap** (which have an executor recheck): the
  index can hand the executor the AND-set with `recheck=true` and let the
  bitmap-heap scan enforce adjacency lazily as rows are consumed — a `LIMIT`ed
  phrase query then never rechecks the whole AND-set.  For `count(*)`/`fts_count`
  there is no LIMIT, so a full-count phrase on a `positions=off` index is
  inherently a full recheck — **document it and steer such users to
  `positions=on`.**
- Do **not** bound the *count* by truncation — that returns a wrong count, which
  is worse than slow.

---

## 7. Recommended sequencing

1. **Ship the interim correctness fix now (0.2.4).**  It is staged, measured,
   installcheck-green, format-identical (no REINDEX).  It fixes a silent
   wrong-results bug for stored-column phrase/NEAR and, as a bonus, gives that
   shape a ~20× phrase-count speedup.  Changelog must be explicit: this fixes
   *stored-column* phrase correctness/latency; the *expression-index* phrase
   count is still slow pending §3.
2. **Then build the positional format (0.3.0), gated hard:**
   - reloption plumbing first (`bm25_options`, `WITH (positions=…)`), default off;
   - 4th FOR column in build + merge + the `Σtf`-bounded writer;
   - lazy `want_positions` decode;
   - positional `FTS_OP_PHRASE` in `bm25_eval_query` reusing `phrase_step`, with
     `need_recheck=false`;
   - `BM25_VERSION` 3 + REINDEX hint;
   - gates before commit: fts_vacuum-reclaims-positional test, 2M build without
     `MaxAllocSize`, ranked/AND/count no >3% regression with `positions=on`
     (lazy-skip proof) and byte-identical results, phrase count in the AND-count
     range with `positions=on`.

Prefer the cheap correct win now; the format change is the real fix and must
clear every P1 gate before it ships.

---

## Appendix — commands / evidence

- Cliff repro + timings: local `pgWith` temp cluster, 200k docs, expression vs
  stored-column index, medians over 3–5 warm runs.
- Bug confirmation: pristine v0.2.3 (clean build, `make clean` first — stale
  `.o` files in the tree will otherwise mask a header change) returns `via_table=f`
  for a same-value stored-vs-in-query phrase; the fix returns `t`.  Erratic-by-
  doc-length table (10=fail,16=pass,17=fail,30=pass on pristine; all pass fixed).
- Regression test `phlong` (sql/pg_fts.sql): pristine → `id=6`, `stored_matches_fresh=f`;
  fixed → `2,4,6,8`, `t`.
- `installcheck-pg17` / `installcheck-pg18`: EXIT 0 with the staged change.

**Methodology caveat that cost time and is worth recording:** the Nix flake builds
from `src = ./.`, which copies any pre-existing `*.o` files; PGXS then treats them
as up-to-date and does **not** recompile after a header-only edit.  Always
`make clean` before a flake build when iterating on `.h` changes, or you will
benchmark the old binary (this masked the fix for several runs here).
