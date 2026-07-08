# Index size + ranked-latency: root causes and the plan to close (and beat) the gap

This supersedes the size/speed root-cause claims in HANDOFF.md §3–4 and the
`positions=off` framing in an earlier ROADMAP.  Every claim here is verified
against the code (file:line cited); where it contradicts the older docs, the
older docs were wrong.

## Measured gap (2.19M Wikipedia, r7i.4xlarge, PG17, median/9 warm)

| | pg_fts | pg_textsearch | VectorChord |
|---|--:|--:|--:|
| index size | 7541 MB | 1831 MB | 1367 MB |
| ranked top-10 rare (`slovakia`, df~11k) | 15.8 ms | 3.3 | **1.6** |
| ranked top-10 common (`year`, df~678k) | 39.9 ms | 13.0 | **1.7** |
| ranked top-100 common | 74.1 ms | 17.0 | **1.9** |

VectorChord is ~flat regardless of df or k; pg_fts degrades with both.

## Finding 0 (the correction): the bm25 index stores NO positions

`BM25Posting` is `{tid, tf, doclen}` — no positions (`pg_fts_am.h:120-127`).  A
block is three FOR columns: docid-gaps, tfs, **doclens** (`pg_fts_am.h:139-145`;
written `pg_fts_am.c:891-921`; decoded `pg_fts_am.c:574-589`).  The build
callback hands the segment writer only `(term, tf, doc->doclen)` — positions are
never given to the index (`pg_fts_am.c:342-344`).  Positions live only in the
heap `ftsdoc` varlena (`pg_fts.h:33-81`, written `pg_fts_analyze.c:184-208`) and
are used by the phrase/NEAR **heap recheck** of the `@@@` qual, not the index
(`pg_fts_am_scan.c:679-682`).

**Consequence:** the 5.5× size gap is *not* "positions, by design," and a
`WITH (positions=off)` mode would **not** shrink the bm25 index (there are no
positions in it) — it would only shrink the heap `ftsdoc` column and speed
build/insert.  Any size plan built on removing index positions is built on a
false premise.

## 1. Size gap — decomposed

Per posting, FOR-packed in a 128-doc block: docid-gap (20–40%), tf (~10%),
**doclen (37–56%)**, block header (~6%).  `doclen` is a per-**document** value
(`doc->doclen`, one per doc) but is stored once per **posting** — i.e. once per
(document × distinct-term) pair (`pg_fts_am.c:243,344,909,921`).  A document with
T distinct terms writes its doclen T times.  FOR makes it worse: the doclen
column is packed to the block's *max* doclen (`bm25_for_pack` width from `maxv`,
`pg_fts_am.c:409-413`), so one long article widens all 128 doclens in its block.

Estimated: doclen-in-postings ≈ 2900–3400 MB (~38–45% of 7541 MB).  Moved to a
**per-segment doclen sidecar** (one FOR-packed value per doc, indexed by docid,
~4 MB total), the index drops to ~4200–4600 MB — a ~40% cut in one change, and
it is *also* a scan speedup (see §3).  The competitors are smaller partly
because they never carried this redundant column (doclen is a per-doc norm/
sidecar for them).

## 2. Rare-term fixed-cost gap (15.8 ms vs 1.6 ms) — pure per-query overhead

A rare term touches few blocks, so decode volume cannot explain 14 ms.  The
ordering scan's first `bm25_gettuple` (`pg_fts_am_scan.c:1188`) does, before any
posting block is decoded:

- **3× metapage reads** — `ReadBuffer`+`LockBuffer`+~6 KB `memcpy`+`Unlock`
  (`bm25_read_meta`, `pg_fts_am_scan.c:237-247`) at `:1266`, `:2515`, `:2621`.
- **3× dictionary lookups per (term,segment)** — sparse-index seek + dict-page
  scan (`bm25_lookup_dict`, `pg_fts_am_scan.c:1585-1640`) at `:2532`, `:2647`,
  `:2660`.
- **Per-candidate slot churn** — `bm25_topk_visible` over-fetches
  `wantk = max(k*4, 64)` (`:2707`) and creates+drops a `TupleTableSlot`
  *per candidate* inside the visibility loop (`:2718-2733`): 64 create/destroy
  cycles for a top-10.

vchord reads its stats once, resolves the term once, and batches visibility, so
it does this in ~1.6 ms.  The "70% irreducible scoring/heap/visibility tail"
from the common-term profile is therefore **not irreducible** — the rare-term
case proves it: near-zero decode, yet ~14 ms of pg_fts-specific overhead.

## 3. Common-term gap builds on the same overhead + the doclen column

The existing profile (bench/NOTE_FORMAT_V3_PROFILE.md) is right that WAND cannot
prune a common term (idf constant across blocks; confirmed by the impact-order
revert, bench/NOTE_IMPACT_ORDERING.md).  But: (a) ~40–56% of the decoded bytes
are the redundant doclen column, so the doclen sidecar (§1) also cuts common-
term decode ~40%; (b) top-100 over-fetches ~400 candidates through the same
per-candidate slot churn (`:1284` grows k to 100 → `wantk` ~400).  So the
common-term cost is real decode of ~every block (of which ~half is doclen) plus
the §2 execution overhead multiplied by a big `wantk`.

## 4. Why vchord is flat — fundamental vs fixable

**Fundamental:** vchord orders **postings by quantized impact** (not blocks by
docid) and runs block-WeakAND with a hard `bm25.limit` top-k.  A moving
threshold skips whole low-impact strata once k results beat the stratum ceiling
— possible because strata are *separated by impact*, unlike docid-ordered blocks
whose per-block bounds all sit in one thin band.  With impact-sorted postings +
hard top-k, work is ~O(k / threshold selectivity), not O(df) — so `year` costs
the same as `slovakia`.  Matching this needs a format change (P4).

**Why the reverted impact-directory doesn't rule this out:** that experiment
ordered *blocks* and recomputed exact bounds (bench/NOTE_IMPACT_ORDERING.md) —
each block still spanned the full impact range, so its bound sat in the same
thin band as every other block's (visited 99.7% of `year`'s blocks).  A
**quantized-impact posting layout** (postings bucketed into impact tiers,
highest tier first) is a *different* structure the revert's finding does not
cover — tiers are separated by construction.

**Fixable (mis-attributed to the codec):** the §2 overhead and the doclen column
are pure pg_fts artifacts, cheap to fix, and help the whole distribution.

## 5. Plan, ranked by value/effort

Legend: [format] = on-disk change (version bump + build path); [exec] = no
format change.

- **P1 — doclen sidecar [format]. Highest-leverage single move.**  −38–45%
  index size (7541 → ~4300 MB) *and* −~40% common-term decode.  Writer stops
  packing the doclen column (`pg_fts_am.c:909,921`); segment gains a doclen
  array indexed by docid; decode (`pg_fts_am.c:574-589`) and the WAND cursor
  read doclen from the sidecar.  `BM25_VERSION` → 3, dual-read for upgrade.  Not
  a reverted experiment.
- **P2 — cache metapage + per-(term,segment) dict entry once per scan [exec].**
  Removes 2 of 3 meta reads and 2 of 3 dict lookups per term.  Most of the
  rare-term 15.8 ms.  Low risk, behavior-preserving.
- **P3 — reuse one TupleTableSlot across the visibility loop; right-size
  over-fetch [exec].**  Kills the 64–400 slot create/destroy cycles; drop
  `wantk` from `max(k*4,64)` toward `k + slack` (the ordering scan already
  retries on shortfall).  Low risk.
  → P2+P3 are the cheap "close most of the rare/mid gap" package; do them first
    (target rare-term 15.8 → ~4–6 ms) before any format work.
- **P4 — impact-quantized posting layout + hard top-k WeakAND [format].**  The
  only thing that makes common-term latency *flat* (74 → low single digits).
  High effort/risk; a different mechanism from the reverted block directory
  (§4).  Sequence after P1 (doclen must leave the posting stream first).
- **P5 — `WITH (positions=off)` [heap-side].**  Shrinks the *heap* ftsdoc column
  and speeds build/insert; does **not** shrink the bm25 index.  Keep as a
  build-speed/heap-size option; fix the ROADMAP framing.
- **P6/P7 — converging `fts_vacuum`, VM-only count, SIMD FOR-unpack.**  Real but
  lower priority; SIMD ROI drops after P1 removes ~40% of the bytes.

## 6. Where pg_fts can pull ahead

After P1 the *index* is a bag-of-words like the competitors', doclen is a shared
sidecar, and phrase uses heap positions on recheck.  If the trigram (fuzzy/regex)
index also becomes optional, pg_fts's index can approach pg_textsearch's size
*while keeping phrase/NEAR* — a feature neither competitor has.  Combined with
its unique index-native `count(*)` and the rich query language (boolean / phrase
/ NEAR / prefix / fuzzy-DFA / regex / BM25F), the target design — doclen sidecar
+ impact-quantized postings + optional trigram/positions + index-native count —
is *both* competitive on size/latency for the common case *and* strictly more
capable than vchord/pg_textsearch everywhere else.  Honest caveat: "smallest for
the phrase-free-and-fuzzy-free profile, and strictly more capable elsewhere," not
"unconditionally smallest," since the feature side-structures cost bytes the
ranking-only engines don't pay.

Measured/verified against pg_fts at the 0.2.0 tree; see
bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md for the numbers and
bench/NOTE_IMPACT_ORDERING.md / NOTE_FORMAT_V3_PROFILE.md / NOTE_PARALLEL_RANKED.md
for the prior reverted experiments this plan does and does not re-tread.
