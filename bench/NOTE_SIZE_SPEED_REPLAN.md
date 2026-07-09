# Size + ranked-latency: a DE-RISKED re-plan after the P1–P4 regression

This supersedes the *plan* in bench/NOTE_SIZE_AND_SPEED.md (§5) and ROADMAP.md
§4's P1–P4 ordering. It does NOT supersede that note's verified FACTS — it keeps
them and discards its predictions, all four of which were wrong at 2.19M scale
(bench/RESULTS_P1_P4.md). Ground truth this time: one change at a time, each
independently benchmarkable and revertible, measurement stated BEFORE commit,
with the specific P1–P4 failure it must avoid.

Verified against v0.2.1 (HEAD 61b6dbd, format v2, P1–P4 reverted at 4b65f20).

---

## 0. What P1–P4 got RIGHT (facts) vs WRONG (predicted impact)

Keep the facts. Never re-cite the predictions.

| Claim in NOTE_SIZE_AND_SPEED | Status |
|---|---|
| bm25 index stores NO positions; `BM25Posting = {tid,tf,doclen}` (pg_fts_am.h:118-123) | **FACT** (confirmed: pg_fts_am.c:658-659, write 762-774) |
| doclen stored once per POSTING (per doc×term), not per doc | **FACT** (write pg_fts_am.c:762,774; a doc with T terms writes doclen T times) |
| doclen column is the widest of the three FOR columns (~38–56% of block bytes) | **FACT** (mechanism confirmed below) |
| rare-term 15.8 ms is mostly per-query fixed overhead, not decode | **FACT** (a rare term touches few blocks; decode can't be 14 ms) |
| ~65–70% of a common-term ranked query is scoring/heap/visibility/executor | **FACT** (perf profile, NOTE_FORMAT_V3_PROFILE.md) |
| "doclen sidecar → ~40% SMALLER index" | **WRONG** — it made the index BIGGER (15 GB vs 4.1 GB) |
| "cache metapage/dict → rare/mid latency DOWN" | **WRONG** — rare/mid rose ~60% |
| "impact tiers → common-term FLAT" | **WRONG** — common +50%, AND 4–12× worse |
| "P1 also cuts common-term decode ~40%" | **UNPROVEN** — decode is lazy already (v0.2.1 only unpacks docids eagerly; tf/dl via bm25_for_get on scored postings only, pg_fts_am_scan.c:2067-2074) |

The last row matters most: v0.2.1 already does the lazy-decode the old note
treated as future work. **The doclen column's cost is now almost entirely SIZE
(bytes on disk + bytes memcpy'd per loaded block), not decode.** A scored posting
extracts one doclen with `bm25_for_get`; that cost does not change if doclen
moves to a sidecar. So any "P1 also speeds the scan ~40%" claim is dead — argue
P1 (if at all) on size alone.

---

## 1. Re-grounded root cause — where the bytes and the milliseconds actually go

### 1a. Size, per-posting, in the CURRENT v2 format

Each 128-posting block = a 24-byte `BM25BlockHdr` (6×uint32, pg_fts_am.h:150-158)
+ three FOR columns, each `[1 width byte][ceil(128·w/8) packed bytes]`. Width is
set by the block's MAX value (pg_fts_for.h:64-72). Modeled for a dense common
term (article corpus):

| column | typical FOR width | bytes / 128-block | B/posting | share of block |
|---|---|---|---|---|
| docid-gaps | ~6 bits (dense) | ~97 | 0.76 | ~21% |
| tf | ~5 bits | ~81 | 0.63 | ~18% |
| **doclen** | **~16 bits** (article tokens 10..50 000+) | **~257** | **2.01** | **~56%** |
| header | — | 24 | 0.19 | ~5% |
| **block total** | | **~459** | **~3.59** | 100% |

The doclen column dominates for one structural reason: FOR packs to the block
**maximum**, and doclen has by far the widest range (a single 50 000-token article
forces all 128 doclens in its block to ~16 bits, even the 20-token ones). gaps
and tf are naturally narrow. This reproduces the note's "doclen 37–56%" with a
mechanism, not a guess. → doclen is ~40–55% of posting bytes; postings are the
bulk of the index; so doclen is plausibly ~35–45% of total index size. **This
number is a MODEL — confirm it with the measurement in §4 before acting on it.**

### 1b. Ranked latency

- **Rare/mid (13–16 ms):** dominated by per-query fixed cost, not decode. Per
  ordering scan: `bm25_read_meta` copies the whole ~6 KB metapage (pg_fts_am_scan.c
  :237-247, all 128 `BM25SegMeta` slots) and is called 3× on the first gettuple
  (:1240, :2710, and inside collect for non-pure-OR). `bm25_lookup_dict` runs
  **twice per (term,segment)** — once for global df (:2784), once for cursor setup
  (:2801). For a single-segment index that's 2 dict page reads/term.
- **Common (40–74 ms):** WAND loads ~every block (idf constant across a term's
  blocks → per-block bounds cluster in a razor-thin band; proven twice —
  NOTE_IMPACT_ORDERING, NOTE_FORMAT_V3_PROFILE). Of the loaded bytes, ~56% is the
  doclen column being memcpy'd (`memcpy(c->blkbuf, stream, bh->bytelen)`,
  pg_fts_am_scan.c ~1928) even though only scored postings unpack it. Then ~65%
  of wall time is scoring/top-k/visibility/executor. The `wantk = max(k*4,64)`
  over-fetch (:2859) pushes ~400 candidates through the per-candidate
  `table_slot_create` + `ExecDropSingleTupleTableSlot` loop (:2880-2890).
- **AND (17–24 ms in v0.2.0/1.20; NOTE: v0.2.1 changed this path):** since 0.2.1,
  a non-pure-OR ranked query runs `bm25_collect_matches` to build an exact @@@
  boolean gate (pg_fts_am_scan.c:2721-2758). That is *correctness* work (fixes the
  reverted P4's AND divergence) but adds a full match-set collection to every AND
  ranked query. **Re-measure AND latency on v0.2.1 before optimizing — it is not
  the 1.20 number in RESULTS_VS_VCHORD.**

### 1c. The ceiling, stated honestly

Codec/size changes are capped at the ~30% decode+load slice, and doclen is now
lazy-decoded so a sidecar barely touches even that 30%. vchord's flatness is
impact-ordered postings + hard top-k — a structure docid-ordered blocks cannot
cheaply emulate (P4 proved a naive tiering regresses). **The size gap is
addressable; the flat-latency gap is not, at acceptable risk.** Say it plainly.

---

## 2. Why P1 made the index BIGGER, not smaller

P1 predicted 7541 → ~4300 MB. It delivered 14.7 → 16.2 GB after build, and the
compacted comparison was 4139 MB (v2) → 15 GB (v4). Three compounding causes,
ranked by contribution:

1. **fts_vacuum stopped reclaiming (dominant).** The fair v2 number is the
   *compacted* 4139 MB after one `fts_vacuum` pass. On v4, fts_vacuum ran 1992 s
   and left the file byte-for-byte unchanged (RESULTS_P1_P4 §Index). So the "15 GB
   vs 4.1 GB" headline is mostly *un-compacted v4 vs compacted v2* — the format
   change broke the compactor's rewrite path. Even a genuinely smaller on-disk
   format looks 3× larger if its bloat can't be reclaimed. **A format change that
   fts_vacuum doesn't understand is an automatic size regression, independent of
   the format's own efficiency.**
2. **New side-structures added bytes the postings didn't lose enough to offset.**
   v4 added a doclen sidecar AND an impact-tier directory per segment. A sidecar
   holding one doclen per (docid) is only worth it if postings shrink by MORE than
   the sidecar costs. But doclen appears per (doc×term); a doc with T terms had T
   copies. Deduping to one copy *should* win on paper — but only if the sidecar is
   itself well-compressed AND FOR's block-max widening is what you were paying for.
3. **Loss of locality / FOR context on the separated column.** In-block, doclen
   FOR-packs against 127 neighbours. A docid-indexed sidecar packs against a
   *different* neighbourhood (docid-adjacent docs, not term-cofid docs). Whether
   that packs better or worse is corpus-dependent and was never measured in
   isolation — P1 shipped it stacked with P2/P3/P4 and a broken vacuum, so the
   sidecar's own size delta is unknown to this day.

**Could a doclen sidecar EVER help?** Conditions, all required:
- fts_vacuum must reclaim the new format (rewrite path updated + tested that a
  post-vacuum size actually drops). Non-negotiable — cause #1.
- The corpus must have high term-per-doc redundancy (T large) so dedup saves more
  than the ~4-byte-per-doc sidecar costs. Wikipedia articles have hundreds of
  distinct terms each → high T → dedup *should* help here specifically.
- The sidecar must be delta/FOR-coded over docid order and must NOT re-introduce a
  per-block widening pathology. A single 50 000-token doc in a docid-adjacent run
  still widens its sidecar block — the same pathology, relocated. Sorting the
  sidecar by docid doesn't escape it. **This is the quiet risk: the sidecar can
  inherit the exact block-max-widening cost that made the column expensive.**

**Honest conclusion on doclen separation:** it is a real but *bounded and
uncertain* size win (model says ~35–45% of postings are doclen bytes; dedup
recovers most of that IF the sidecar compresses well), gated on fixing
fts_vacuum, and it delivers **~zero latency benefit** (decode is already lazy).
It is NOT the "highest-leverage single move." It is a size-only, format-change,
vacuum-coupled bet — the single riskiest category, per P1. **Do it only after the
cheap exec-only wins are measured, and only behind the isolation experiment in
§4.** If §4 shows the sidecar doesn't compress dramatically better than the
in-block column, drop doclen separation permanently and say so.

---

## 3. Independent candidate improvements, ranked (exec-only first)

Legend: **[exec]** no on-disk change, low risk, revert = delete the diff.
**[format]** on-disk change, HIGH risk, must pass §4-style isolation + a
fts_vacuum-reclaim test + a 2M build test before it can ship.

### C1 [exec] — Cache the metapage once per scan. LOWEST risk, do first.
- **Mechanism:** read the metapage once into the scan's `BM25ScanOpaque` and pass
  it to `bm25_topk_candidates_range` instead of re-reading (currently 2–3
  `bm25_read_meta` per query, each a full ~6 KB copy). Behaviour-preserving.
- **Effect:** removes 2 of 3 metapage reads/copies. Bounded by how much of the
  15.8 ms is those copies (probably 1–2 ms; a 6 KB memcpy warm is cheap, so DON'T
  over-promise).
- **Measure BEFORE:** `perf` the rare-term ranked top-10; confirm `bm25_read_meta`
  / `memcpy` self-time is actually >1 ms. **If it isn't, skip C1 entirely** —
  this is exactly the kind of "obvious" fix that P2/P3 assumed and got wrong.
- **P1–P4 risk it must avoid:** P2/P3 *regressed* rare-term ~60% while "caching"
  things. Root-cause that first (§3a) before touching this path at all.

### C2 [exec] — Collapse the double dict lookup to one per (term,segment).
- **Mechanism:** `bm25_topk_candidates_range` calls `bm25_lookup_dict` once for
  df (:2784) then again for cursor setup (:2801). Merge: look up once, keep
  (df, max_tf, firstblk, firstoff), sum df in a first pass over cached results.
- **Effect:** halves dict page reads per term. Rare-term win bounded by dict-read
  count (small).
- **Measure BEFORE:** count `ReadBuffer` calls on `BM25_DICT` pages for a
  rare-term query (add a temporary counter, or `perf` `bm25_lookup_dict`
  self-time). Confirm it's >1 ms.
- **Risk:** low. But same P2/P3 warning — do §3a first.

### C3 [exec] — Reuse ONE TupleTableSlot across the visibility loop.
- **Mechanism:** `bm25_topk_visible` does `table_slot_create` +
  `ExecDropSingleTupleTableSlot` **per candidate** (pg_fts_am_scan.c:2880-2890),
  up to `wantk`≈400 for top-100. Hoist one slot before the loop, `ExecClearTuple`
  each iteration, drop once after. Standard PG pattern.
- **Effect:** removes ~64–400 slot create/destroy cycles per query. This is the
  most likely real exec win because it scales with `wantk` — helps common/top-100
  most.
- **Measure BEFORE:** `perf` common-term top-100; confirm slot alloc/free
  (`table_slot_create`, `ExecDropSingleTupleTableSlot`, `MakeTupleTableSlot`)
  shows measurable self-time.
- **Risk:** low, but MVCC-correctness-sensitive (the slot feeds
  `table_index_fetch_tuple`). Must pass the ground-truth ranked parity test.

### C4 [exec] — Right-size the over-fetch `wantk = max(k*4,64)`.
- **Mechanism:** the ordering scan already retries-and-grows on shortfall
  (:1264-1289), so the 4× MVCC slack is belt-and-suspenders. Try `wantk = k +
  slack` (e.g. k+32).
- **Effect:** fewer candidates scored AND fewer visibility fetches — could help
  common-term more than C1/C2 combined, since it shrinks the ~65% tail's input.
- **Measure BEFORE / kill criterion:** measure common-term top-10 AND top-100 AND
  a high-deletion table (where over-fetch earns its keep). **If the retry path
  fires often enough to net-lose on any of these, revert.** This is a tuning
  knob, not a fix — leave it as a `ponytail:`-style tunable, not a hardcoded
  constant.
- **Risk:** medium — smaller over-fetch means more recompute passes on
  high-deletion tables. This is the one exec change that can regress; gate hard.

### C5 [exec] — Re-examine the v0.2.1 AND path cost.
- **Mechanism:** since 0.2.1, non-pure-OR ranked queries run a full
  `bm25_collect_matches` gate (correctness, replaces reverted-P4 behaviour). For a
  common&mid AND this collects a large match set every query.
- **Effect:** unknown — possibly the dominant cost of AND ranked now.
- **Measure BEFORE:** benchmark v0.2.1 AND ranked latency fresh (the
  RESULTS_VS_VCHORD 17–24 ms is a 1.20 number and predates this gate). Only then
  decide if it needs work (e.g. cache the gate across k-growth recomputes — it's
  recomputed on every `bm25_topk_visible` call inside the grow loop).
- **Risk:** correctness-critical — this gate is what fixed the P4 AND divergence.
  Do NOT weaken it; only avoid recomputing it redundantly.

### C6 [format, HIGH risk] — doclen sidecar, size-only, vacuum-coupled.
- Only after §4 proves the size win in isolation AND fts_vacuum reclaims it.
- Zero latency benefit (decode already lazy). Size-only. See §2 for the ceiling.

### Explicitly NOT proposed (already reverted, don't re-tread)
- Impact-ordered block directory (NOTE_IMPACT_ORDERING) — bounds cluster.
- Impact-tiered postings + hard top-k (P4) — regressed 4–12× on AND.
- Reusable fixed block buffer (NOTE_FORMAT_V3_PROFILE) — measured slower.
- Parallel ranked CustomScan (NOTE_PARALLEL_RANKED) — Amdahl-capped, workers
  didn't launch.

### 3a. WHY did P2/P3 "caching" make rare terms SLOWER? (must root-cause first)
This is the counterintuitive result that should make us humble. Caching the
metapage/dict should be free or positive; it regressed rare/mid ~60%. Hypotheses
to test (with `perf diff` v0.2.0 vs the P2/P3 commit 04f434e, NOT by re-reasoning):
1. **The "cache" wasn't a cache — it changed control flow.** P2/P3 was committed
   *stacked* on nothing yet (it's the first of the four), but measured only as
   part of the HEAD stack. **We may have no clean P2/P3-alone number at all** —
   RESULTS_P1_P4 measured HEAD (all four + build patch), not 04f434e in isolation.
   If so, the "-60%" is not attributable to P2/P3 — it could be P4's traversal
   changes bleeding into rare/mid via shared code. **Verify which commit the -60%
   belongs to before ever retrying C1/C2.** This alone may exonerate caching.
2. If it truly was 04f434e: a per-scan cache that outlives its validity (e.g.
   caching a dict entry across segments, or a metapage snapshot that a concurrent
   merge invalidated) forces a slow revalidation path. Check for added
   locking/recheck.
3. Cache stored in a wider/differently-aligned struct → worse cache-line behaviour
   on the hot cursor array.
**Do not retry C1/C2 until this is root-caused.** Bisecting 04f434e alone at 2M is
the prerequisite experiment — it may show C1/C2 were never the problem.

---

## 4. Recommended FIRST experiment

**C3 (reuse one TupleTableSlot) — but gated behind a measurement, not committed
blind.**

Rationale: it's exec-only (no format, no vacuum coupling, trivially revertible),
it targets the ONE overhead that provably scales with `wantk` (so it can't be a
rounding-error win the way a single metapage copy might be), and it's the least
entangled with the P2/P3 mystery (it's in `bm25_topk_visible`, not the
metapage/dict path that regressed).

**Step 0 (before any code):** `perf --no-children` the common-term ranked top-100
on v0.2.1 at 2M and confirm slot create/destroy self-time is measurably nonzero
(target: >2 ms combined). **If it isn't, C3 is not the first experiment — fall
back to §3a (bisect the P2/P3 regression) as the real first task**, because then
we don't understand the hot path well enough to change it.

**The change (if step 0 passes):** hoist one `table_slot_create` before the loop
in `bm25_topk_visible`, `ExecClearTuple` per iteration, drop once after.

**Kill criterion (revert if ANY):**
- common-term top-100 ranked not faster by ≥5% (median/9, warm, 2M), OR
- ANY ranked query (rare/mid/common/AND, top-10/top-100) regresses beyond noise
  (>3%), OR
- the ground-truth ranked parity test (see below) changes output, OR
- `--enable-cassert` build warns or the visibility path trips an assert.

**Non-negotiable gate for EVERY change here:** add a ground-truth ranked-parity
test FIRST — a seq-scan exact BM25 top-k vs the index top-k on a fixed corpus.
RESULTS_P1_P4 §Correctness found BOTH v0.2.0 and HEAD silently drop true top-k
docs on common and AND queries. That pre-existing WAND/MaxScore inexactness must
be pinned by a test before we perturb the scan path, or we'll ship latency wins
that quietly worsen recall and never know.

---

## 5. Honest bottom line

**The size gap is partially closable at bounded risk; the flat-latency gap is
not, at acceptable risk/effort.**

- **Latency:** the exec-only wins (C1–C5) are real but small — they chip at the
  ~30% overhead slice, and the profile's ~65–70% scoring/heap/visibility/executor
  tail is largely irreducible in PG's executor. Realistic outcome: rare/mid maybe
  13–16 → 8–12 ms, common maybe 40–74 → 30–55 ms. That still leaves pg_fts
  multiples slower than vchord's 1.6–1.9 ms flat. vchord's flatness needs
  impact-ordered postings + hard top-k, which docid-ordered blocks can't cheaply
  match and which P4 already proved regresses when bolted on naively. **Do not
  promise flat latency. Do not attempt another impact-tier format.**
- **Size:** the doclen sidecar is a genuine but uncertain ~35–45%-of-postings win
  — IF the sidecar compresses well AND fts_vacuum is fixed to reclaim the new
  format. It is size-only (no latency benefit, decode is already lazy) and is the
  riskiest category (format + vacuum coupling), so it comes last, gated by §4-style
  isolation. Even at best, pg_fts stays larger than vchord/pg_textsearch because
  it carries a term dictionary, per-segment tombstones, and an optional trigram
  index the ranking-only engines don't pay for.

**HANDOFF.md §6 is right, and this analysis reinforces it:** pg_fts's honest
competitive position is **richer query language (boolean/phrase/NEAR/prefix/
fuzzy-DFA/regex/BM25F) + index-native `count(*)` + MVCC/WAL correctness**, not
raw ranked QPS or smallest index. The correct strategy is:
1. Ship the cheap exec wins that survive their kill criteria (C3, likely C4; C1/C2
   only after the P2/P3 regression is root-caused). Small, safe, honest.
2. Pin the ranked-exactness bug with a ground-truth test and FIX it — a wrong
   top-k is worse than a slow one, and it's independent of the format.
3. Treat the doclen sidecar as an optional, isolation-gated, vacuum-coupled
   size experiment — not a headline feature, and killable if §4 disappoints.
4. Invest the remaining effort in the moat (query language, count, correctness,
   hybrid filter+rank), where the competitors are absent — not in a fourth format
   rewrite chasing a latency number the format fundamentally can't hit.

**What this plan does NOT know without a benchmark** (stated deliberately):
- whether ANY of the metapage/dict overhead exceeds noise (C1/C2 gated on it);
- which commit the P2/P3 "-60%" actually belongs to (may be unattributed);
- the v0.2.1 AND ranked latency (the cited number predates the correctness gate);
- whether a docid-ordered doclen sidecar compresses better or worse than the
  in-block column (never measured in isolation — P1 shipped it stacked).
Every one of these is a measurement, not a prediction. Take them one at a time.

Verified against pg_fts v0.2.1 (HEAD 61b6dbd). Size model: FOR block math in
pg_fts_for.h + block layout pg_fts_am.h:150-158 / pg_fts_am.c:762-819. Latency
facts: NOTE_FORMAT_V3_PROFILE.md profile + pg_fts_am_scan.c hot path. Regression
facts: RESULTS_P1_P4.md. Predictions from NOTE_SIZE_AND_SPEED.md are discredited
and not reused.