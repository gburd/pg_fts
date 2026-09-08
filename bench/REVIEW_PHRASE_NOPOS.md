# REVIEW — `phrase_step()` presence-only fallback: what the fix should be

Read-only review. No `.c`/`.h`/`.sql` file was modified. Every claim below is
either cited to `file:line` on HEAD or was **run** on a live cluster (PG 17.10,
store-built pg_fts 1.5.10, `initdb` at `/tmp/ftsrev_pgdata2`, socket
`/tmp/ftsrev_sock2:55472`). Claims marked *unverified* were not executed.

The verification changed two of the brief's premises. Both are load-bearing:

- **There is a fourth `pos == NULL` producer**, and it does not come from the
  document at all — it comes from the *query shape*. This kills option 3
  (synthesize positions) as a complete fix, and it is the single strongest
  argument for fixing `phrase_step` rather than the producers.
- **Upstream `tsquery`'s answer to this exact situation is `false`, not an
  error, and not AND.** `tsearch/ts_utils.h:195-200` states the rule outright.
  That gives "return no match" a precedent the other options lack.

---

## Recommendation

| # | Question | Recommendation |
|---|---|---|
| 1 | Error, notice, false, or document? | **Return no match (`false`).** Not `ereport`. |
| 2 | Prefix-in-phrase | **Keep it working, gate on `FTS_DOC_HAS_POS(doc)`.** One-line condition, no restructuring. Do *not* add a `MatchVal` field. |
| 3 | The producers | **Change none of them. Do not synthesize positions.** Synthesis is unsound (it would invent adjacency that never existed) and incomplete (misses producer 4). |
| 4 | `sql/pg_fts.sql:2800` | **Correct to `f`.** Do not delete, do not make it an error assertion. Two more assertions need the same treatment. |
| 5 | Zone filtering (`wmask`) | **Match nothing on a positionless doc.** Drop the "unlabelled == D" equivalence. |

One sentence: `phrase_step` and the `wmask` branch should answer "the data
cannot support this claim, so no" — which is what upstream does, is sound,
requires ~6 lines across two sites, and keeps a table with a few bad rows
queryable.

---

## 1. Why `false`, not `ereport(ERROR)`

The prior analysis argued for a hard error. I recommend against it, on three
grounds, in descending order of weight.

### 1a. Upstream already decided this, and chose `false`

`tsearch/ts_utils.h:195-200` (PG 17.10 headers):

> If `TS_EXEC_PHRASE_NO_POS` is set, allow `OP_PHRASE` to be executed lossily
> in the absence of position information: a true result indicates that the
> phrase *might* be present. **Without this flag, `OP_PHRASE` always returns
> false if lexeme position information is not available.**

pg_fts's fallback is precisely the lossy variant, with the flag permanently on,
in call sites that have no "might" semantics available to them. Verified:

```
strip(to_tsvector('simple','quick brown')) @@ to_tsquery('simple','quick <-> brown')  =>  f
```

Note the words *are* adjacent in that source text and upstream still says `f`.
Upstream is not merely refusing to guess — it refuses to claim a phrase it
cannot prove, and it does so without erroring. `pg_fts_match.c:10` states the
matcher "mirrors tsquery's `TS_execute` strategy". On this branch it does the
opposite. Aligning is a bug fix toward the stated design, not a new policy.

### 1b. An error is order-dependent, so it is not a reliable signal

`@@@` is a scan-time qual. Whether a mid-scan error fires depends on the plan,
not on the query. Demonstrated with a proxy predicate that raises exactly on the
rows a `phrase_step` error would fire on (403-row table, 3 positionless rows):

```
SELECT count(*) FROM mixdoc WHERE boom2(d);                       -- ERROR
SELECT count(*) FROM (SELECT id FROM mixdoc WHERE boom2(d) LIMIT 5) s;  -- 5, no error
```

Same predicate, same table. One plan errors, the other returns rows. An error
that appears and disappears with `LIMIT`, `ANALYZE` results, or parallel worker
count is a worse diagnostic than a sound `false`, because a user cannot
reproduce it on demand and cannot rely on its absence to mean "clean data".

### 1c. Blast radius: 3 bad rows take down 400 good ones

Measured on the mixed table (400 positioned rows, 3 positionless via `strip()`):

```
seqscan   "quick brown"  =>  203   (200 correct + 3 leaked)
index positions=off      =>  203
index positions=on       =>  203
fts_count (both indexes)  =>  203
ranked <=> LIMIT 500     =>  403 rows scanned, no filter
```

All five callers leak, confirming the single-guard argument. But under an error
policy each of those five becomes a *total query failure* over a table that is
99.3% clean. The realistic shape here is an incremental adoption — a table
partly backfilled via `to_ftsdoc(strip(...))`, the rest via `to_ftsdoc(cfg,text)`
— and the error turns a precision bug affecting 3 rows into an outage affecting
the whole table. `false` returns the 200 correct rows and silently drops the 3
unprovable ones, which is the sound answer.

The prior analysis's counter-argument was that ranked/count paths have no second
filter, so a wrong answer there is final. That is correct and it is exactly why
the answer must change — but `false` changes it just as completely as an error
does, without the outage. On the mixed table, `false` yields 200 from every one
of the five callers.

### 1d. Rejected variants

- **`NOTICE`/`WARNING` + keep AND.** The wrong row is still returned; the
  warning fires once per row on a seq scan (thousands of duplicates), and
  `fts_count`'s wrong number still ships. It adds noise without fixing the
  result. Reject.
- **Leave it, document loudly.** Rejected on the evidence: `fts_count` returns a
  confidently wrong integer with no recheck (`pg_fts_am_scan.c:3520` region),
  and `CAPABILITIES.md:15` advertises phrase match without qualification.
  Documentation cannot reach a user reading a count.
- **Hard error.** 1a–1c above.

### 1e. The recall objection, answered

`false` reduces recall on positionless docs. That is intended: the current
"recall preserved" is recall of *wrong* rows. A phrase query that returns
conjunction results has not preserved recall of the phrase — the phrase result
set was never computed. And `false` is safe for the index paths: candidate
generation treats `PHRASE` as `AND` (`pg_fts_am_scan.c:835-838`, comment "PHRASE
is treated as AND for candidate generation; the bitmap heap recheck enforces
adjacency exactly"), so making the recheck *more* selective keeps the index a
superset. Verified today's superset invariant holds:
`count(AND) >= count(PHRASE)` => `t`. No missed rows, no index rebuild.

---

## 2. Prefix-in-phrase verification

Both halves of the prior analysis's claim are **confirmed**.

### (a) Does `"quick bro*"` take the fallback branch on a positioned doc? Yes.

`pg_fts_match.c:65-69` returns presence-only for `FTS_QF_PREFIX`, with
`v.pos == NULL` regardless of the document:

```c
if (flags & FTS_QF_PREFIX)
{
    /* presence only; phrase-with-prefix is not tracked positionally */
    v.present = fts_doc_has_prefix(doc, term, termlen);
    return v;
}
```

The parser does accept a prefix inside `"..."` (`pg_fts_query.c:403`) and inside
`NEAR(...)` (`pg_fts_query.c:441`), and preserves the flag —
`'"quick bro*"'::ftsquery` renders as `('quick' <-> 'bro'*)`. On fully positioned
docs:

```
to_ftsdoc('simple','quick brown fox') @@@ '"quick bro*"'   =>  t   (adjacent: right for the wrong reason)
to_ftsdoc('simple','brown quick')     @@@ '"quick bro*"'   =>  t   (NOT adjacent -> fallback taken)
to_ftsdoc('simple','quick red brown') @@@ '"quick bro*"'   =>  t   (gap -> fallback taken)
to_ftsdoc('simple','brown quick')     @@@ '"qui* brown"'   =>  t   (prefix on the left too)
to_ftsdoc('simple','fox brown quick') @@@ '"quick bro* fox"'  =>  t   (poisons a 3-term chain)
to_ftsdoc('simple','quick green')     @@@ '"quick bro*"'   =>  f   (absence still correct)
```

It degrades on a `positions = on` index too, so this is not a recheck artifact
(`bm25_phrase_chain` rejects prefix operands at `pg_fts_am_scan.c:1594`, routing
to the same `phrase_step`):

```
100 adjacent rows + 100 non-adjacent rows, index WITH (positions = on):
  "quick brown"  =>  100   (exact term: adjacency enforced)
  "quick bro*"   =>  200   (prefix: adjacency NOT enforced)
  fts_count(...,'"quick bro*"')  =>  200
```

Upstream enforces adjacency here, so this is a genuine pg_fts-only defect:

```
to_tsvector('simple','quick brown fox') @@ to_tsquery('simple','quick <-> bro:*')  =>  t
to_tsvector('simple','brown quick')     @@ to_tsquery('simple','quick <-> bro:*')  =>  f
to_tsvector('simple','quick red brown') @@ to_tsquery('simple','quick <-> bro:*')  =>  f
```

### (b) Is it untested? Yes, genuinely.

Searched `sql/*.sql` and `expected/*.out` for a `*` inside a phrase or `NEAR`,
in every spelling (`"… *"`, `NEAR(… *`, `<-> …*`, tsquery `:*`). The only hits
are `expected/pg_fts.out:4307` (an `ftsquery_out` rendering test, no matching)
and `sql/pg_fts.sql:2390` (`to_tsquery('english','quick:*')` — a bare prefix, not
in a phrase). No test asserts a prefix-in-phrase *match result*. Nothing pins the
current behaviour, so changing it breaks no test.

### The concrete discrimination condition

The two cases **are** cleanly distinguishable, and more cheaply than the prior
analysis assumed. Its S1a proposed a new `MatchVal` field. That is unnecessary:
the distinguishing fact is a property of the *document*, which `phrase_step`
does not currently receive but which is one parameter away.

```
"operand is a prefix, positions inherently unavailable"  <=>  FTS_DOC_HAS_POS(doc) && pos == NULL
"document has no positions at all"                       <=>  !FTS_DOC_HAS_POS(doc)
```

These are exhaustive and mutually exclusive, because on a positioned doc the
*only* way a `MatchVal` reaches `phrase_step` with `pos == NULL` is a
flag-bearing leaf or a boolean sub-expression — enumerated below and, critically,
narrowed to just two cases:

- `FTS_QF_REGEX` (`pg_fts_match.c:56-60`) — **unreachable in a phrase.** The
  phrase parser drops the regex flag: `'"quick /bro.*/"'::ftsquery` renders as
  `('quick' <-> 'bro.*')`, a plain term. Verified: matching gives `f`, and
  `/bro.*/` standalone gives `t`, so the flag really is gone.
- `FTS_QF_FUZZY` (`pg_fts_match.c:61-64`) — **unreachable in a phrase.** Same:
  `'"quick brwn~1"'` renders as `('quick' <-> 'brwn')`.
- `FTS_QF_PREFIX` (`pg_fts_match.c:65-69`) — **reachable.** Verified above.
- `FTS_QF_WEIGHTED` — cannot combine with prefix; `'quick:A*'::ftsquery` is a
  syntax error. On a positioned doc the weighted branch keeps `v.pos` non-NULL
  when any position is in-zone (`pg_fts_match.c:110-117`), so it does not reach
  the fallback with `pos == NULL` unless out-of-zone, where `present = false`
  makes the AND result `false` anyway — the same answer either way.
- Boolean sub-expression under `PHRASE` — **reachable, see §3d.**

So `FTS_DOC_HAS_POS(doc)` is a complete discriminator, and prefix is the only
flagged leaf it has to admit. Minimal shape:

```c
/* phrase_step gains the doc (or just the bool) as a parameter */
if (left.pos == NULL || right.pos == NULL)
{
    if (!FTS_DOC_HAS_POS(doc))
        return r;                /* r.present == false: cannot prove adjacency */
    r.present = left.present && right.present;   /* prefix/boolean: documented approximation */
    return r;
}
```

`phrase_step` is `static` with exactly one caller (`pg_fts_match.c:226`), which
already holds `doc`, so threading it through is a two-line signature change and
no restructuring. **No `MatchVal` field, no new flag, no format change.**

### But prefix-in-phrase is itself a bug worth a separate ticket

Keeping it working preserves a shipped behaviour, and that is the right call for
*this* change — it is out of scope and nothing pins it either way. It is still
wrong (upstream gets it right, and pg_fts gets it wrong even on a
`positions = on` index). The real fix is to deliver on the promise already
written at `pg_fts_match.c:40-41`:

> "for a prefix term we merge the position lists of all matching terms (rare, so
> a simple concat + sort)"

That comment describes the correct implementation. The code at
`pg_fts_match.c:65-69` does not do it — it calls `fts_doc_has_prefix`
(`pg_fts_doc.c:717`), which returns a bool. The doc comment is aspirational and
contradicts its own function. Making it true (walk the sorted entry range from
the prefix lower bound, concat each `FTS_DOC_TERMPOS`, sort) would fix
prefix-in-phrase properly and is straightforward, but it is a separate change
with its own tests. **Recommend: fix the comment or file it; do not bundle.**

---

## 3. Producer-by-producer disposition

Recommendation: **change no producer.** Two reasons, then the per-producer detail.

### 3a. Synthesis is unsound — it invents adjacency

The brief's option 3 asks whether the other producers should synthesize ordinal
positions like the raw-text path. They must not, and the reason is decisive: the
raw-text path has *real token order to preserve*, and the other paths do not.

`'bravo alpha'::ftsdoc` renders as `'alpha':1@2 'bravo':1@1` — note the positions
are **2, 1**, not entry order. The analyzer knows `bravo` came first. Entry order
is alphabetical; token order is independent information the analyzer holds.

A positionless doc has lost that information irrecoverably. Synthesizing from
entry order does not recover it, it fabricates a different document:

```
source text:            'zz quick brown'      (quick -> brown IS adjacent)
strip(to_tsvector(...)) => 'brown' 'quick' 'zz'   (alphabetical; token order gone)
to_ftsdoc(that)         => 'brown':1 'quick':1 'zz':1
synthesis from entry order would assign brown@1 quick@2 zz@3, i.e. it would
  answer TRUE for "brown quick" (never in the text) and FALSE for
  "quick brown" (actually in the text).
```

That is strictly worse than today. Today both queries return `t` (one right, one
wrong). Under synthesis one returns `f` and the other `t` — **inverted**, and now
with `FTS_DOC_HAS_POS` set, so no downstream guard can ever detect it. It
converts a detectable precision loss into an undetectable fabrication. Upstream
returns `f` for both, which is the only sound answer.

Second problem: `$$'x':3$$::ftsdoc` has `tf=3` and no positions. Synthesis must
invent 3 distinct ascending ordinals (`fts_doc_build` requires strictly
ascending, `pg_fts_doc.c:170-173`) for a term whose occurrences are unknown.
Pure fiction, and it changes `doclen` semantics relative to the entry data.

### 3b. Synthesis is incomplete — it cannot reach producer 4

Even if synthesis were sound, it would not close the hole, because the fourth
producer's missing positions come from the query, not the document. See §3d. Any
producer-side fix leaves that path silently wrong. Only a `phrase_step`-side fix
covers all of them. This is the root-cause argument: one guard at
`pg_fts_match.c:178`, not three producer patches plus a miss.

### 3c. The three producers, individually

**Producer 1 — canonical literal without `@`** (`pg_fts_doc.c:431-436`, built at
`:451`). Confirmed:
`$$'brown':1 'quick':1$$::ftsdoc @@@ '"quick brown"'` => `t`. The raw-text form
`'brown quick'::ftsdoc` correctly gives `f` (it synthesizes real positions via
`pg_fts_doc.c:464` -> `fts_analyze_text`), which is why this mis-tests easily.

Disposition: **keep accepting it.** It is the documented dump/restore format —
`ftsdoc_out` (`pg_fts_doc.c:486-520`) emits exactly this shape for a positionless
doc, so rejecting it on input would break `ftsdoc::text::ftsdoc` round-trip for a
value the type can hold. Verified round-trip is currently exact and idempotent.
The literal *cannot* carry token order anyway: entries must be sorted
(`pg_fts_doc.c:281-287`; `$$'quick':1 'brown':1$$` errors "terms must be sorted
and distinct"), so literal order is alphabetical by construction and carries zero
adjacency information. Synthesis here would be fabrication in its purest form.

**Producer 2 — `to_ftsdoc(tsvector)` all-or-nothing** (`pg_fts_tsanalyze.c:264-272`,
`has_pos = false` if any entry is positionless). Confirmed:
`to_ftsdoc(strip(to_tsvector('simple','brown quick'))) @@@ '"quick brown"'` => `t`.

Disposition: **keep.** The brief asks whether `strip()`'s explicit intent to
discard positions makes synthesis wrong. It does, and more strongly than the
brief suggests — `strip()` is not merely *permitting* position loss, it is the
user asserting positions are not wanted. Manufacturing them would override an
explicit instruction. Upstream honours it by returning `f`.

The all-or-nothing rule deserves a note but not a change. A *mixed* tsvector
(`$$'brown' 'quick':1$$::tsvector`) loses `quick`'s real position too:
`to_ftsdoc` of it renders `'brown':1 'quick':1` and answers `t` for
`"quick brown"`, where upstream answers `f`. Under recommendation 1 both give
`f`, so the coarseness stops mattering for correctness. Refining to per-entry
positions is a possible later precision improvement (it would let `quick`'s real
position participate), *unverified* whether the layout supports per-entry
position presence — `FTS_DOCF_POSITIONS` is a whole-doc flag (`pg_fts.h:69`), so
probably not without a format change. Out of scope.

**Producer 3 — `ftsdoc || ftsdoc`** (`pg_fts_doc.c:904`,
`has_pos = HAS_POS(a) && HAS_POS(b)`). Confirmed:
`($$'brown':1$$::ftsdoc || to_ftsdoc('simple','quick')) @@@ '"quick brown"'` => `t`.

Disposition: **keep the flag rule**, but note this producer is worse than the
other two, because it destroys labels the other side legitimately had:

```
to_ftsdoc('simple','quick','A')                        =>  'quick':1@1A
to_ftsdoc('simple','quick','A') || $$'zz':1$$::ftsdoc  =>  'quick':1 'zz':1      -- label A gone
  ... @@@ 'quick:D'  =>  t     -- FALSE POSITIVE: quick was A, not D
  ... @@@ 'quick:A'  =>  f     -- FALSE NEGATIVE: quick WAS A
```

This is the documented multi-field idiom (`pg_fts_doc.c:886-897`) producing a
false positive on zone filtering. Recommendation 5 fixes the false positive (`:D`
-> `f`); the false negative is inherent to discarding the labels and is the
correct conservative answer once "unlabelled == D" is dropped. Synthesizing
ordinals would not restore labels either — labels are separate information in the
high bits (`pg_fts.h:147-152`) — so synthesis does not help here at all.

Worth considering separately: `||` could *preserve* positions when only one side
lacks them, by synthesizing ordinals for the positionless side only. Same
soundness objection (fabricated intra-side adjacency), so **not recommended**,
but it is a smaller fiction than the whole-doc case. Filed, not proposed.

### 3d. Producer 4 — a boolean sub-expression as a phrase operand (NEW)

Not in the brief. **Reachable in shipped SQL, on a fully positioned document.**

`fts_doc_matches` unconditionally nulls the position list in the AND, OR and NOT
arms — `pg_fts_match.c:220-221` (NOT), `:234-235` (AND), `:242-243` (OR), each
`stack[...].pos = NULL; stack[...].npos = 0;`, as the struct comment at
`pg_fts_match.c:29` says ("Boolean operators (AND/OR/NOT) collapse to presence
and drop positions"). If such a value becomes a `PHRASE` operand, `phrase_step`
sees `pos == NULL` on a perfectly positioned doc.

pg_fts's own grammar cannot express it (`'"quick (brown & fox)"'::ftsquery` and
`'NEAR(quick (brown & fox), 2)'::ftsquery` are both syntax errors), but the
**shipped `tsquery` -> `ftsquery` cast reaches it** (`pg_cast`: `tsquery` ->
`ftsquery`, context `a`; `pg_fts_migrate.c:113-115` maps `OP_PHRASE` faithfully):

```
q  := (to_tsquery('simple','quick <-> (brown & fox)'))::ftsquery   -- ('quick' <-> ('brown' & 'fox'))
to_ftsdoc('simple','fox brown zzz quick') @@@ q                    =>  t     (pg_fts)
to_tsvector('simple','fox brown zzz quick') @@ to_tsquery(...)     =>  f     (upstream)

(to_tsquery('simple','(brown & fox) <-> quick'))::ftsquery         =>  t     (left side too)
(to_tsquery('simple','quick <-> (brown | fox)'))::ftsquery on 'fox zzz quick'  =>  t
   upstream on the same input                                       =>  f
```

`ftsquery_recv` also admits the shape: it validates only that each operator is
one of NOT/AND/OR/PHRASE (`pg_fts_query.c:1092-1098`), not the operand kinds, so
a binary-protocol client can construct it directly.

Disposition: **covered for free by recommendation 2's condition, and correctly.**
On a positioned doc the recommended code takes the `FTS_DOC_HAS_POS(doc)` branch
and keeps the presence-only AND — matching current behaviour, so no regression is
introduced by this change. It remains a divergence from upstream (which is
position-aware here: `'quick <-> (brown | fox)'` on `'quick brown'` => `t`, on
`'brown quick'` => `f`), and fixing it properly means teaching the boolean arms
to propagate merged positions for OR and intersected ones for AND. Larger than
this fix. **File separately.** The material point for *this* review is that its
existence rules out any producer-side-only fix.

---

## 4. Test changes required

Searched for every place the suite depends on the degradation. Found **three**
sites, not one.

### Must change from `t` to `f`

| Site | Assertion | Now | After |
|---|---|---|---|
| `sql/pg_fts.sql:2800` / `expected/pg_fts.out:5423-5426` | `$$'brown':1 'quick':1$$::ftsdoc @@@ '"quick brown"'` as `phrase_nopos_degrades_to_and` | `t` | **`f`** |
| `sql/pg_fts.sql:2801` / `expected/pg_fts.out:5429-5432` | `$$'fox':1 'quick':1$$::ftsdoc @@@ 'NEAR(quick fox, 1)'` as `near_nopos_degrades_to_and` | `t` | **`f`** |
| `sql/pg_fts.sql:2969` (uncommitted, `git status`: ` M sql/pg_fts.sql`) | `to_ftsdoc(strip(...)) @@@ '"quick brown"'` as `nopos_via_strip_tsvector` | `t` | **`f`** |
| `sql/pg_fts.sql:2970` (uncommitted) | `($$'brown':1$$::ftsdoc \|\| to_ftsdoc('simple','quick')) @@@ '"quick brown"'` as `nopos_via_concat` | `t` | **`f`** |

**Correct to `f`, do not delete.** These are the highest-value tests in the file
— they are the ones that catch the bug. Deleting them removes the regression
guard. Renaming matters too: `phrase_nopos_degrades_to_and` and
`near_nopos_degrades_to_and` assert the defect *in their names*; they should
become e.g. `phrase_nopos_no_match` / `near_nopos_no_match`. Same for the
comment at `sql/pg_fts.sql:2797-2799`, which explains the degradation as
intended, and `pg_fts.sql:2765-2766`, which describes the section as covering
"phrase/NEAR degrading to AND-only".

Not an error assertion, per recommendation 1.

### Must change under recommendation 5 (zone)

| Site | Assertion | Now | After |
|---|---|---|---|
| `sql/pg_fts.sql:2974` (uncommitted) | `$$'quick':1$$::ftsdoc @@@ 'quick:D'` as `nopos_zone_D_always_matches` | `t` | **`f`** |

`sql/pg_fts.sql:2973` (`quick:A` => `f`) is already correct and stays.

### Verified NOT affected

- `sql/pg_fts.sql:2958-2961` (`nopos_*`, raw-text cast). Positions are
  synthesized there (`'bravo alpha'::ftsdoc` => `'alpha':1@2 'bravo':1@1`), so
  `FTS_DOC_HAS_POS` holds and all four keep their current values. The block
  comment at `:2951-2957` claims these assertions "keep that fallback
  unreachable" — that claim is false (they only cover the raw-text path) and
  should be corrected while nearby.
- `sql/pg_fts.sql:92-93` (`tsvector_stripped_match`): a plain-term query on a
  stripped doc, `t`. Unchanged — the fix is scoped to `PHRASE`.
- `sql/pg_fts.sql:2678` and `:2874`: positionless docs inserted into the
  validity table, queried with a plain term (`'alpha'`). Unchanged.
- `sql/pg_fts.sql:2936-2947` (`zold` zone tests, incl. `labelD_matches`,
  `phrase_ok`): the docs are `to_ftsdoc('english', ...)`, fully positioned
  (`pg_fts_tsanalyze.c:143` always sets positions). Recommendation 5 only
  touches the `!FTS_DOC_HAS_POS` branch, so these are untouched. Verified
  `to_ftsdoc('simple','quick brown','A')` => `'brown':1@2A 'quick':1@1A`.
- `sql/pg_fts.sql:1540-1640`, `:2947` and the `pos3`/`posbig`/`pos_on`/`pos_off`
  blocks: all positioned. Untouched.
- Prefix-in-phrase: no test exists (§2b), so recommendation 2 breaks nothing.

### Tests to add

The uncommitted block at `sql/pg_fts.sql:2963-2974` already covers producers 2
and 3 plus both zone cases — keep it, flip the three expectations. Add:

```sql
-- producer 4: a boolean sub-expression as a phrase operand, via the shipped
-- tsquery cast, on a FULLY POSITIONED doc (positions dropped by the AND arm,
-- pg_fts_match.c:234-235).  Presence-only AND is retained here deliberately.
SELECT to_ftsdoc('simple','fox brown zzz quick')
       @@@ (to_tsquery('simple','quick <-> (brown & fox)'))::ftsquery
  AS boolean_operand_in_phrase_presence_only;   -- t (documented approximation)

-- prefix-in-phrase keeps working on a positioned doc (pg_fts_match.c:65-69):
-- currently presence-only, so a non-adjacent match is admitted.  Pins the
-- behaviour the FTS_DOC_HAS_POS gate deliberately preserves.
SELECT to_ftsdoc('simple','quick brown fox') @@@ '"quick bro*"'::ftsquery
  AS prefix_in_phrase_adjacent;    -- t
SELECT to_ftsdoc('simple','brown quick')     @@@ '"quick bro*"'::ftsquery
  AS prefix_in_phrase_nonadjacent; -- t (imprecision, pinned deliberately)
SELECT to_ftsdoc('simple','quick green')     @@@ '"quick bro*"'::ftsquery
  AS prefix_in_phrase_absent;      -- f

-- the mixed-table case: a few positionless rows must not contaminate the
-- phrase count over many positioned ones (this is the user-visible bug).
CREATE TABLE npos_mix (id serial, d ftsdoc);
INSERT INTO npos_mix(d) SELECT to_ftsdoc('simple','alpha quick brown fox pad'||g)
  FROM generate_series(1,20) g;                                   -- adjacent
INSERT INTO npos_mix(d) SELECT to_ftsdoc('simple','alpha quick red brown pad'||g)
  FROM generate_series(1,20) g;                                   -- not adjacent
INSERT INTO npos_mix(d) SELECT to_ftsdoc(strip(to_tsvector('simple','brown zz quick pad'||g)))
  FROM generate_series(1,3) g;                                    -- positionless
CREATE INDEX npos_mix_i ON npos_mix USING fts (d);
-- pending-list scan FIRST (before any merge): pg_fts_am_scan.c:2251
SET enable_seqscan = off;
SELECT count(*) = 20 AS phrase_pending_ok  FROM npos_mix WHERE d @@@ '"quick brown"'::ftsquery;
RESET enable_seqscan;
SELECT count(*) = 20 AS phrase_seqscan_ok  FROM npos_mix WHERE d @@@ '"quick brown"'::ftsquery;
SELECT fts_merge('npos_mix_i') IS NOT NULL AS npos_merged;
SET enable_seqscan = off;
SELECT count(*) = 20 AS phrase_bitmap_ok   FROM npos_mix WHERE d @@@ '"quick brown"'::ftsquery;
SELECT fts_count('npos_mix_i', '"quick brown"'::ftsquery) = 20 AS phrase_count_ok;
SELECT count(*) = 20 AS phrase_ranked_ok FROM
  (SELECT id FROM npos_mix ORDER BY d <=> '"quick brown"'::ftsquery LIMIT 100) s
  WHERE s.id IN (SELECT id FROM npos_mix WHERE d @@@ '"quick brown"'::ftsquery);
RESET enable_seqscan;
-- the commutator, and a positionless doc still matching non-phrase queries
SELECT '"quick brown"'::ftsquery @@@ to_ftsdoc(strip(to_tsvector('simple','brown zz quick')))
  AS commutator_nopos_f;                                          -- f
SELECT to_ftsdoc(strip(to_tsvector('simple','brown zz quick'))) @@@ 'quick & brown'::ftsquery
  AS nopos_conjunction_still_t;                                   -- t
SELECT to_ftsdoc(strip(to_tsvector('simple','brown zz quick'))) @@@ 'quic*'::ftsquery
  AS nopos_prefix_still_t;                                        -- t
DROP TABLE npos_mix;
```

The pending-list ordering matters: `pg_fts_am_scan.c:2251` calls
`fts_doc_matches` on raw pending-page bytes, so it must be exercised *before*
`fts_merge`. Verified the pending path leaks today (205 with 2 extra pending
positionless rows), so it is a real distinct path.

Also worth updating: `CAPABILITIES.md:15` advertises phrase/NEAR match with no
positionless caveat. A one-line note ("phrase/NEAR require token positions; a
positionless `ftsdoc` — from `strip()`, a `@`-less literal, or concatenation with
one — cannot match a phrase") is warranted, since `false` is a silent answer even
when it is the sound one.

---

## 5. Zone-filter disposition

`pg_fts_match.c:88-99`:

```c
if (!FTS_DOC_HAS_POS(doc))
    v.present = (wmask & 1u) != 0;   /* unlabeled == label D */
```

Confirmed: `$$'quick':1$$::ftsdoc @@@ 'quick:A'` => `f`,
`@@@ 'quick:D'` => `t`.

**Recommendation: match nothing (`v.present = false`).** Drop the equivalence.

The reasoning is not symmetry with recommendation 1, it is that "unlabelled == D"
is a **false positive** on the very idiom that produces these docs. Producer 3's
measurement above: a doc whose `quick` was explicitly labelled `A` answers `t` to
`quick:D` after concatenation destroyed the label. The doc is not asserting D —
it is asserting nothing, and `:D` is a specific claim about a specific zone. On a
positioned doc, label D means "the analyzer saw this token and assigned it the
default zone" (`pg_fts.h:143-146`, label 0 = D). On a positionless doc no such
observation exists.

Note this is where I diverge from upstream, deliberately. Upstream matches *every*
mask on a positionless entry (`$$'quick'$$::tsvector @@ to_tsquery('quick:A')`,
`:B`, `:D`, `:AB` — all `t`), i.e. it is maximally permissive rather than
maximally conservative. Two reasons not to copy it here:

1. Upstream's choice is consistent with *its* phrase choice only in being lossy
   in the recall direction; pg_fts's `wmask` feeds the same `v.pos` that
   `phrase_step` consumes (`pg_fts_match.c:110-117` narrows `v.pos` to in-zone
   positions), so a permissive `wmask` on a positionless doc would keep feeding
   unprovable presence into the phrase machinery we just made strict.
2. pg_fts's current behaviour is not upstream's anyway — it matches D only, not
   everything. So "keep the current behaviour" is not "match upstream". Given a
   change is needed either way, the conservative direction is the one consistent
   with recommendation 1.

Rejected alternatives: **error** — same order-dependence and blast-radius
objections as §1b/§1c, and `term:A` on a table with three stripped rows should not
fail. **Keep "D matches everything"** — it is a demonstrated false positive
(§3c), which is the failure mode this whole review is about.

Cost: `sql/pg_fts.sql:2974` (uncommitted) flips `t` -> `f`. The `zold` zone tests
at `sql/pg_fts.sql:2936-2947`, including `labelD_matches`, use positioned docs
and are unaffected.

---

## 6. Risks of the recommended fix

Ordered by likelihood times severity.

1. **Silent recall drop for a user relying on the AND behaviour.** Someone whose
   corpus is entirely positionless and who writes phrase queries currently gets
   conjunction results and may have tuned around them. After the fix they get
   zero rows, with no error explaining why. This is the real cost of choosing
   `false` over `ereport`, and it is the strongest argument the other way.
   Mitigation: CHANGELOG entry and the `CAPABILITIES.md` note in §4. Judgement:
   accept — zero rows for an unprovable phrase is sound and matches upstream,
   whereas wrong rows are not, and an error would fail their non-phrase queries
   too.
2. **Behaviour change in a patch release.** `sql/pg_fts.sql:2797-2801` documents
   the degradation as intended, so this is a deliberate-behaviour reversal, not
   an obvious typo fix. Needs a CHANGELOG entry and probably a minor version
   bump, not a patch. *Unverified*: this project's stated version-bump policy for
   behaviour changes (did not read `RELEASING.md`).
3. **Index/heap divergence.** Low. Candidate generation treats PHRASE as AND
   (`pg_fts_am_scan.c:835-838`) and the recheck narrows; a stricter recheck keeps
   the index a superset. Verified the superset invariant holds today. No REINDEX
   needed — no stored format changes, `flags` and `version` untouched.
4. **`phrase_step` signature change touching the positional index path.** The
   shared `fts_phrase_step_pos` (`pg_fts_match.c:130-157`) is *not* changed —
   only the `static phrase_step` wrapper, which has one caller. The index
   evaluator `bm25_phrase_eval_seg` (`pg_fts_am_scan.c:1810-1814`) calls
   `fts_phrase_step_pos` directly and already returns
   `BM25_POSLOOKUP_NOPOS` -> fall back to recheck, so it inherits the new
   behaviour without modification. Byte-identical index/recheck answers preserved
   (the property `pg_fts_match.c:124-128` promises).
5. **Prefix-in-phrase stays wrong.** Deliberate (§2). Risk is that keeping it
   makes the fix look inconsistent — strict for positionless docs, lax for
   prefix. Mitigation: the new tests pin it explicitly as an approximation, and
   the follow-up ticket names the real fix.
6. **Producer 4 stays wrong.** Deliberate (§3d). Only reachable via the tsquery
   cast or binary protocol, and preserving current behaviour there means this
   change introduces no regression on that path.
7. **Zone change could surprise a positionless multi-field user.** Low volume —
   requires `||` with a positionless side *and* `term:D` queries. Their `:D`
   results are currently false positives.

Not a risk: performance (the changed branch is a comparison), on-disk format,
`ftsdoc::text::ftsdoc` round-trip (verified exact and idempotent today, and no
producer changes), binary send/recv (`pg_fts_doc.c:637-661` / `:568`,
`has_pos` byte round-trips exactly; verified a positionless doc's wire image
`0004…` carries `has_pos=0` and no positions region).

---

## 7. What I could not verify

- **Whether a released pg_fts version behaved differently**, i.e. whether the AND
  fallback is longstanding or recent. `git log -- pg_fts_match.c` shows only 4
  commits, the newest being the 1.4.0 field-zone release; I did not bisect the
  fallback's introduction. Affects the version-bump question (risk 2).
- **This project's version-bump policy for a deliberate behaviour reversal.** Did
  not read `RELEASING.md` or `CHANGELOG.md` conventions.
- **Whether any real user depends on `to_ftsdoc(strip(...))`.** It is the
  documented tsvector adoption on-ramp (`pg_fts_tsanalyze.c:229-238`), which is
  why it is the most likely real-world source, but adoption is unknown. Bears on
  urgency, not on the recommendation.
- **Whether per-entry position presence is representable** without a format
  change, for the mixed-tsvector refinement in §3c. `FTS_DOCF_POSITIONS` is a
  whole-doc flag (`pg_fts.h:69`), so likely not, but I did not work through the
  layout.
- **The exact upstream `TS_execute` code path** for positionless phrase and for
  boolean-under-phrase. I read the contract in `tsearch/ts_utils.h:195-200` and
  measured the behaviour, but did not read `tsrank.c`/`tsvector_op.c` sources
  (not present in the Nix dev closure — headers only).
- **Parallel-worker and custom-scan paths.** I exercised seq scan, bitmap heap
  recheck, pending-list scan, `fts_count`, and the ranked `<=>` scan. I did not
  force a parallel plan or the `pg_fts_customscan.c` count pushdown with a
  positionless row; both route through `fts_doc_matches`
  (`pg_fts_am_scan.c:2345`, `:2251`) so the single guard should cover them, but
  that is inference, not measurement.
- **A build of the proposed change.** I did not compile or run the suite with the
  fix applied — this was a read-only review, and the recommended diff is
  described but not written. The flipped expectations in §4 are predictions from
  the code path, corroborated by the measured current values.
