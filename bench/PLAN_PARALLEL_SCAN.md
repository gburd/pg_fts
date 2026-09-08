# Feasibility: parallel ranked scan (ROADMAP 7, `amcanparallel`)

Read-only analysis, 2026-09. No code changed. Every claim about existing code
cites `file:line`. Anything I could not confirm from the tree is marked
**unverified**.

---

## Summary: **NO-GO as a latency fix. CONDITIONAL GO as a throughput-scaling
## feature, and only after re-measuring the doclen split.**

Three findings, in order of how much they should change the decision.

**1. This was already built, measured, and reverted.**
`bench/NOTE_PARALLEL_RANKED.md` documents a complete parallel ranked
CustomScan: `set_rel_pathlist_hook` detection, a `FtsRankedScan` producing heap
tuples, a docid-range-bounded WAND, DSM worker coordination, and a leader-side
k-way merge with visibility. It was verified byte-identical to serial. It was
reverted for two measured reasons: an Amdahl ceiling of ~30% parallelizable, and
**workers refusing to launch from inside `ExecCustomScan` on EC2 (0 workers,
silent fall back to serial)**. The docid-range plumbing was deliberately kept as
the retry hook and is still in the tree today:
`pg_fts_am_scan.c:3851` (`bm25_topk_candidates_range`), the
`docid_lo`/`docid_hi` cursor fields at `pg_fts_am_scan.c:2759-2761`, the
prime-time seek at `pg_fts_am_scan.c:2932-2933`, and the range-exhaustion cutoff
at `pg_fts_am_scan.c:3000-3001`. Any new work here is a **retry of a known
design**, not a greenfield build, and the retry inherits a documented failure
mode that has nothing to do with the algorithm.

**2. Even a perfect implementation does not reach 2.1 ms.** With the whole
scan parallelized — the optimistic reading of the profile, where the serial
residue is only the ~11% not itemized — 8 workers land at **~6.0 ms**, and 4 at
~9.3 ms. Against pg_search's 2.12 ms that is still 2.8x behind at 8 workers,
using 8 CPUs to do it. Under the conservative reading (the WAND driver loop is
serial per worker but the shared-resident-doclen caching degrades), the ceiling
is worse. **Parallelism cannot close this gap; it can only narrow it.** Arithmetic below.

**3. The natural parallel unit does not exist on the benchmark index.**
Per-segment parallelism is the obvious split — the code is already a
`for (s = 0; s < meta.nsegments; s++)` loop at `pg_fts_am_scan.c:3987` — but the
benchmark index is `nsegments = 1` after `fts_merge` (`bench/NOTE_WAND_PRUNING_2026-09-04.md:23`,
"one segment"; `bench/NOTE_BUILD_FLUSH_QSORT_SPIN.md:28`, "nsegments=1"), and
that is not an accident of the harness: the tiered merge actively drives toward
few large segments (`pg_fts_am.c:5234`) and `fts_vacuum` compacts to one
(`bench/RESULTS_5WAY_158_2026-09-04.md:45`). **A healthy pg_fts index has nothing
to divide by segment.** Intra-segment docid-range splitting works and is what the
reverted prototype did, but it changes the cost model (see §3).

**What I would do instead:** nothing here yet. The single most valuable next
measurement is not a parallel prototype, it is **one `perf` run on 1.5.10 to
confirm the post-fix profile split**, because the split cited in the task
(candidates 39% / doclen 43%) is a *derived* number, not a measured one — see
§2.0. If the doclen path really is 43%, the highest-value lever is making that
path cheaper or removable for high-df terms (which is a smaller change than
parallelism and helps every band), not dividing it across 8 CPUs.

If parallelism is pursued anyway, the mechanism question has a clear answer:
**`amcanparallel` on the existing `amgettuple` ordering scan, not a
CustomScan** — the reverted prototype's own conclusion
(`bench/NOTE_PARALLEL_RANKED.md`, "Direction if revisited"), and independently
correct because `create_index_path` already generates a parallel KNN path when
`amcanparallel` is set (`indexpath.c:984-1006` in `~/ws/_postgresql`). But it is
a poor fit for a *batch* top-k engine; see §4.

---

## 1. Profile split: what is parallelizable

### 1.0 A correction on the input numbers

The task states the post-1.5.10 split as candidates 39% / doclen 43% /
`wand_load_block` ~6%. **That split is not in the notes.** What
`bench/NOTE_PROFILE_COMMON_TERM_2026-09-06.md:63-68` records is the profile at the
*intermediate* `+hint` build (42.67 ms), before the second 1.5.10 fix landed:

```
46.58%  bm25_topk_candidates_range
21.33%  bm25_doclen_cursor_load_page
17.80%  bm25_doclen_cursor_lookup
 4.98%  wand_load_block
```

Doclen is 39.1% there and candidates 46.6%. The 39/43 split appears to be that
profile re-normalized for the second fix (fast `bm25_for_get`, 42.67 → 36.16 ms),
which removed time from `wand_contrib_cur` — inlined into
`bm25_topk_candidates_range`'s slice — thereby shrinking the candidates share and
inflating doclen's. That is a plausible reconstruction and I will use it, but
**no `perf` run on 1.5.10 exists in the tree, so treat 39/43 as unverified.**
Every ceiling below is computed on both splits; they differ by under 1 ms, so the
conclusion does not turn on this. It still matters for the *next* decision (§8).

### 1.1 What each slice is, and whether a worker can own it

Common `year` k10 = **36.16 ms** total (`CHANGELOG.md:14`).

| slice | share | parallelizable? | why |
|---|---|---|---|
| `bm25_topk_candidates_range` (WAND driver + inlined `wand_contrib_cur`) | 39% | **yes, fully** | Pure per-posting work. Split the docid space; each worker scores a disjoint subset. Already plumbed. |
| doclen path (`_load_page` + `_lookup`) | 43% | **yes, but degrades** | Per-posting sidecar probes. Parallelizable, with a caveat (§1.2). |
| `wand_load_block` | 6% | **yes** | Per-block page read + FOR-unpack of the docid column. |
| unitemized residue (setup, dict lookups, tombstone load, MVCC visibility, executor, qsort) | ~12% | **mostly no** | See §1.3. |

### 1.2 The doclen caveat: parallelism partly un-does the 1.5.10 fix

The two 1.5.10 wins depend on **ascending locality**, and the doclen path is
shared per segment. `bm25_doclen_cursor_lookup` keeps one resident 128-entry
block per segment and hits it linearly via a resume hint
(`pg_fts_am.c:2478-2483`; the hint reset is `pg_fts_am.c:2400`). On serial `year`
this achieves a **95.5% hint hit rate and 15,220 page loads for ~17,094 sidecar
blocks — each block decoded about once**
(`bench/NOTE_PROFILE_COMMON_TERM_2026-09-06.md`, "instrumented call counts").

Under docid-range partitioning each worker gets a *contiguous* docid range, so
each worker's own probes stay ascending and its own hint still hits. Total page
loads should stay ~15,220 across workers plus one boundary block each. So the
first-order answer is: **the fix survives**, unlike an interleaved (round-robin)
partition, which would destroy it. This is a real argument in favour of
contiguous ranges over any striped split.

But two second-order costs appear:

- The relcache page directory (`BM25DoclenDirCache`, `pg_fts_am.c:2241`) is
  per-backend, built by a header-only walk of every sidecar page
  (`bm25_doclendir_count_seg` at `pg_fts_am.c:2203`, then
  `bm25_doclendir_scan_seg`). **Every worker builds its own copy.** At ~17k
  sidecar pages on the 2.19M corpus this is not free — the note that motivated
  the directory design measured the *old* whole-segment decode at ~534 page
  reads (`CHANGELOG.md:173`), and the directory walk touches far more pages than
  that, headers-only. It is amortized to once-per-backend serially, but a
  parallel worker is a fresh backend each query. **This cost is
  unverified and could be significant relative to a 6 ms target.** It is the
  single biggest measurement risk in the whole design.
- `doclenres` is allocated per segment and shared across a query's cursors
  (`pg_fts_am_scan.c:3889-3890`), giving the documented multi-term win
  (`pg_fts_am.c:2470-2472`). Workers cannot share it — it is palloc'd private
  memory holding decoded state. Single-term common `year` has one cursor so
  loses nothing; **multi-term ranked queries lose the cross-term block reuse**,
  a regression exactly where parallelism would otherwise help.

### 1.3 What is inherently serial

- **Setup, once per worker, not divided.** `bm25_read_meta`
  (`pg_fts_am_scan.c:3881`), per-segment dictionary lookups run *twice* per term —
  once to sum global df at `pg_fts_am_scan.c:3993-3999`, once per cursor at
  `pg_fts_am_scan.c:4013` — and `bm25_tombstones_load` at
  `pg_fts_am_scan.c:3975`. Every worker repeats all of it. Amdahl's law treats
  replicated work as *worse* than serial: it does not shrink, and it consumes a
  core.
- **MVCC visibility.** `bm25_topk_visible` fetches each candidate from the heap
  one tuple at a time (`pg_fts_am_scan.c:4149-4157`). With `wantk = k*4`
  (`pg_fts_am_scan.c:4099`) that is ~40 heap probes for k10 — small here, but it
  is the ~40% serial tail the reverted prototype called out, and it grows with k.
  A worker could do its own slice's visibility if it emits ranked *visible* rows,
  which is exactly why the note concluded a partial-path AM beats internal DSM.
- **Final merge and sort.** `qsort` at `pg_fts_am_scan.c:3588`, plus a
  leader-side k-way merge of W partial heaps. O(W·k log) — negligible at k=100.
- **Parallel setup.** `parallel_setup_cost` defaults to 1000.0
  (`cost.h:30`), the planner's proxy for real per-worker fork/DSM-attach cost.
  Wall-clock worker startup is commonly ~1-3 ms — **unverified for this rig**,
  but on a 36 ms query aiming at 6 ms, startup is not a rounding error. It is
  ~15-50% of the target.

---

## 2. Amdahl ceiling — arithmetic

`T(W) = T_serial + T_parallel / W`, plus per-worker startup `S`.

Baseline **T = 36.16 ms**, common `year` k10, 2.19M docs
(`CHANGELOG.md:14`).

### Case A — optimistic: candidates + doclen + load_block all parallelize

Parallel fraction p = 0.39 + 0.43 + 0.06 = **0.88**; serial 0.12.

- T_parallel = 36.16 × 0.88 = **31.82 ms**
- T_serial   = 36.16 × 0.12 = **4.34 ms**

| W | T_parallel/W | + serial | ceiling (S=0) | with S=2 ms |
|---|---|---|---|---|
| 1 | 31.82 | 36.16 | 36.16 | — |
| 2 | 15.91 | 4.34 | **20.25** | 22.25 |
| 4 |  7.96 | 4.34 | **12.30** | 14.30 |
| 8 |  3.98 | 4.34 | **8.32**  | 10.32 |
| ∞ |  0    | 4.34 | 4.34 | 6.34 |

### Case B — same, treating the intermediate profile's split as authoritative

p = 0.466 + 0.391 + 0.050 = 0.907, on the 42.67 ms build, then scaled to 36.16
by assuming the second fix removed only parallelizable time. Serial ≈ 3.36 ms.

| W | ceiling (S=0) |
|---|---|
| 2 | **19.76** |
| 4 | **11.56** |
| 8 | **7.46** |

Within 1 ms of Case A at every W. **The unverified split does not change the
conclusion.**

### Case C — realistic: add the costs §1.2/§1.3 identified

Each worker pays: its own `bm25_doclendir_cache` build (call it D), its own meta
read + 2× dict lookups + tombstone load (call it U), and startup S. These do not
divide. Guessing D + U ≈ 1.5 ms and S ≈ 2 ms (**both unverified**):

| W | 4.34 + 31.82/W + 3.5 |
|---|---|
| 2 | **23.7** |
| 4 | **15.8** |
| 8 | **11.8** |

### Verdict against 2.1 ms

> **Best achievable common k10 wall-clock, perfect implementation, 8 workers:
> ~6.0-8.3 ms optimistically, ~11.8 ms realistically. pg_search is 2.12 ms.
> Parallel scan cannot reach the bar. It closes at most 4.4x of a 17x gap, and
> spends 8 CPUs to do it.**

Efficiency framing, for the record: at W=8 the optimistic ceiling is 4.3x speedup
on 8 workers = 54% efficiency; realistic is 3.1x = 38%. That is not
disqualifying for a wall-clock-only feature, but it means **throughput under
concurrent load gets worse, not better** — 8 backends each spawning 8 workers is
64 processes for the work of 8. pg_fts's competitive strengths (smallest index
1421 MB, fastest exact `count(*)` 2.20 ms —
`ROADMAP.md:267-274`) are not helped, and its per-core efficiency is spent.

The honest positive case: **20 → 12 ms on 4 workers is a real user-visible
improvement** for a low-QPS analytical workload where CPUs are idle. It is just
not "competitive with Tantivy", and the plan should not be sold as if it were.

---

## 3. Parallel unit, and the `nsegments = 1` problem

### 3.1 Per-segment: natural, already coded, and empty

The scan already loops segments at `pg_fts_am_scan.c:3987` and
`pg_fts_am_scan.c:4009`, creating one cursor per (term, segment)
(`pg_fts_am_scan.c:3969-3971`, up to `nterms × nsegments` cursors). Handing each
worker a segment subset is a ~20-line change and trivially exact: cursors are
already per-segment, tombstones are already per-segment
(`pg_fts_am_scan.c:3973-3974`, `wand_cur_own_tombstoned` at
`pg_fts_am_scan.c:2967`), and IDF is computed from **global df summed across all
segments before partitioning** (`pg_fts_am_scan.c:3999-4003`), so a worker that
sees only some segments still scores identically. That last property is not
luck — it is what makes any partition scheme safe here.

**But `nsegments = 1` is the healthy state, and it is enforced.** Confirmed:

- The benchmark rig: "one segment" (`bench/NOTE_WAND_PRUNING_2026-09-04.md:23`),
  `nsegments=1` (`bench/NOTE_BUILD_FLUSH_QSORT_SPIN.md:28`),
  `fts_vacuum`'d to one segment
  (`bench/NOTE_PHRASE_POSITIONS_FIX.md:58`,
  `bench/RESULTS_5WAY_158_2026-09-04.md:45`).
- It is deliberate: the insert-time tiered merge runs opportunistically on every
  flush (`pg_fts_am.c:5234`), autovacuum cleanup merges and compacts
  (`pg_fts_am.c:5965-5975`), and 1.5.0's slowdown report was *caused* by
  many-segment indexes — the doclen cursor design comment at
  `pg_fts_am_scan.c:4028-4031` explicitly notes a whole-segment preload "on a
  many-segment index dominated the scan".
- Worse, more segments makes each query *slower* serially. So per-segment
  parallelism only ever helps an index that is in a state the project treats as
  unhealthy, and its speedup is capped at the segment count.

**Per-segment parallelism is a non-starter.** Not "needs care" — it divides by
one on every index anyone should be running.

### 3.2 Intra-segment docid ranges: workable, and already prototyped

This is what the reverted work did, and the plumbing survives:
`bm25_topk_candidates_range(index, q, wantk, docid_lo, docid_hi, &out)` at
`pg_fts_am_scan.c:3851`. Serial callers pass `[0, UINT64_MAX)`
(`pg_fts_am_scan.c:4126`). Cursors carry the bounds
(`pg_fts_am_scan.c:2759-2761`), seek to `docid_lo` at prime time
(`pg_fts_am_scan.c:2932-2933`), and self-exhaust past `docid_hi`
(`pg_fts_am_scan.c:3000-3001`) so the WAND and MaxScore loops need no range
awareness — they already terminate when all cursors report `UINT64_MAX`
(`pg_fts_am_scan.c:3405`, `pg_fts_am_scan.c:3663`).

Docids are `blkno × MaxHeapTuplesPerPage + offset` (`pg_fts_am.c:692-698`), so a
docid range is a **heap block range** — splitting on it is as easy as splitting a
seq scan, and the bounds are computable from the heap size without reading the
index.

Three real costs:

1. **Seek is not free.** `wand_prime` → `wand_seek(c, docid_lo)`
   (`pg_fts_am_scan.c:2932`) walks block *headers* forward from the term's first
   block via `wand_skip_blocks` (`pg_fts_am_scan.c:3060`). There is **no
   random access into a posting chain**: pages are a singly-linked `nextblk`
   list (`pg_fts_am_scan.c:2820`) and docids are gap-encoded, so worker W must
   header-walk past all W−1 preceding slices. Total seek cost across workers is
   O(W²/2) page *reads* — headers-only, no FOR decode, so cheap per page, but for
   `year` that is 5,743 posting blocks (`bench/NOTE_WAND_PRUNING_2026-09-04.md`)
   over ~15,220 page loads, and the last of 8 workers walks ~7/8 of the chain
   before scoring anything. **This is the main reason W=8 will underperform the
   Amdahl ceiling**, and it is not fixable without a format change (a per-term
   block directory with absolute docids — which is what
   `bench/NOTE_IMPACT_ORDERING.md` built and reverted for other reasons).
2. **Load imbalance.** Equal docid ranges are equal *heap block* ranges, not
   equal posting counts. For `year` (df 734,896 of 2.19M = 34%) postings are
   spread near-uniformly so this is mild; for a term clustered in a docid region
   one worker does everything. Mitigable by ranging on posting *count*
   (df/W per worker) instead — but finding those boundaries needs the same
   header walk as (1), so it converts imbalance into seek cost.
3. **Pruning gets weaker, not just unchanged.** Each worker builds its own
   threshold from its own top-k. A worker with only 1/8 of the corpus reaches a
   lower k-th score, so its block-max bound prunes *less*. On this corpus that
   costs almost nothing — `bench/NOTE_WAND_PRUNING_2026-09-04.md` establishes
   only 500 block-skips of 5,743 blocks for `year`, so there is nearly no pruning
   to lose. **This is one place the flat-plateau finding helps the design.** On a
   corpus where WAND *does* prune, partitioning would be actively harmful, and
   total work would rise superlinearly.

**By posting-block range instead of docid range?** Cleaner for balance (each
worker takes df/W postings) but strictly worse otherwise: block boundaries must
be discovered by the same forward header walk, and it breaks multi-term queries,
where each term's chain must be split at *the same docid* for cursors to
intersect. Docid range is the right unit. The prototype chose correctly.

---

## 4. Exactness

**The scheme is exactly exact, and the reason is stronger than "the ranges are
disjoint".**

Composition: each worker w runs the full engine over `[lo_w, hi_w)` and returns
its local top-`wantk` (`ScoredTid[]`, descending, `pg_fts_am_scan.c:3588`). The
leader concatenates all W arrays and takes the global top-`wantk` by score.

Why this is exact:

1. **Ranges partition the docid space disjointly and completely** — no doc is
   scored twice or missed. Codified in the existing comment at
   `pg_fts_am_scan.c:2755-2757`.
2. **A document's score is independent of which other documents the worker
   sees.** This is the load-bearing property. `wand_contrib_cur`
   (`pg_fts_am_scan.c:3021-3030`) computes `idf·(k1+1)·tf / (tf + k1(1−b) +
   k1·b·dl/avgdl)` from per-posting `tf`, per-doc `dl`, and query-level `idf`
   and `avgdl`. `idf` comes from global df summed over all segments *before* any
   partitioning (`pg_fts_am_scan.c:3999-4003`); `avgdl` and `N` come from the
   metapage (`pg_fts_am_scan.c:3883-3884`). **No term in the score depends on the
   worker's slice.** So worker w's score for doc d is bit-identical to serial's.
3. **Top-k of a partition union = top-k of the union of top-ks**, provided each
   partial list is at least k long or is exhaustive. Standard, and it holds here
   because each worker asks for the same `wantk`.

**What each worker's threshold must be: its own local k-th best score, and
nothing else.** A worker cannot use a global threshold, and must not try. The
threshold is only ever an *admission bound for its own heap*
(`pg_fts_am_scan.c:3537-3541`, `pg_fts_am_scan.c:3553-3556`), and its only
effects are pruning decisions (`pg_fts_am_scan.c:3437`,
`pg_fts_am_scan.c:3651`). A local threshold is always ≤ the global one, so it
prunes *less* — never more. **Under-pruning costs time; it cannot lose a
result.** That asymmetry is what makes the design safe. The existing code already
relies on the same asymmetry for the boolean gate: a gated-out doc leaves the
threshold lower, "costing pruning only, never correctness"
(`pg_fts_am_scan.c:3524-3527`).

Sharing a live global threshold via DSM would be a legitimate *optimization*
(more pruning) and would still be exact, since any threshold ≤ global-k-th is
sound. **Do not build it**: on this corpus there is nearly nothing to prune
(500 skips of 5,743 blocks), so it buys ~0% and adds a shared-memory write on
the hottest loop in the engine. Skipped, add if a corpus is found where WAND
prunes and partitioning measurably hurts.

### Ways this could go approximate — the disqualifying list

Each is a real hazard; each has a specific guard.

- **`wantk` per worker must be the full `wantk`, not `wantk/W`.** All k top docs
  can live in one worker's slice. Dividing k is the obvious "optimization" and it
  silently truncates results. Non-negotiable; total work is W×wantk heap slots,
  which is trivial.
- **Ties.** `cmp_scored_desc` (`pg_fts_am_scan.c:2682-2692`) compares score only
  and returns 0 for equal scores — `qsort` is not stable, so tie order is already
  unspecified serially. Parallel merge does not make this worse, but "byte-exact"
  cannot be claimed for tie-adjacent results in either mode. Note that
  `bench/parity_check.sh` does not test tie order: it checks that every returned
  doc's exact score is ≥ the true k-th score, within `PARITY_TOL` (default 1%,
  for v4 doclen quantization). So parity would pass even if tie order shuffled.
  **A reordered tie is not a correctness bug, but it will make byte-diff
  regression output noisy** — the `expected/*.out` files do compare exact row
  order (`sql/pg_fts.sql`, `sql/idx_scan_stats.sql` both use `ORDER BY <=>`).
  Fix by making the comparator break ties on TID; that is a 3-line change and
  arguably should be done regardless.
- **Missing boundary docs.** Correctness rests on `hi_w == lo_{w+1}` exactly and
  half-open intervals. The existing cutoff is `c->docid >= c->docid_hi`
  (`pg_fts_am_scan.c:3001`) — half-open, correct. An off-by-one here loses or
  duplicates a doc and *parity would likely still pass*, since one wrong doc out
  of k is only caught if its score falls below the k-th cutoff. **This needs a
  direct partition-invariant test, not reliance on parity.** The reverted
  prototype did verify parallel == serial byte-identical, so the plumbing is
  known good.
- **`nsegments` changing mid-scan.** Handled by the generation guard, but the
  guard is per-worker; see §5.
- **The pending list is not ranked at all.** Pre-existing and documented
  (`pg_fts_am_scan.c:3833-3838`): docs in the pending buffer are matched by `@@@`
  but not ranked until merged. Parallelism neither helps nor hurts this.

**Nothing here makes the result approximate if the guards hold.** This is not
the reason to say no.

---

## 5. Interaction with 1.5.7's concurrency invariants

1.5.7 fixed three races (`CHANGELOG.md:228-250`). Parallel workers touch two of
the three mechanisms.

### 5.1 The generation guard becomes W independent guards — the real problem

Serially, candidate generation is bracketed: read generation, generate, re-read,
discard and retry if it moved, up to 10 times
(`pg_fts_am_scan.c:4123-4132`). This exists because a concurrent merge/vacuum can
free and recycle pages mid-scan — the A1 race — and the read path is deliberately
tolerant: `bm25_scan_readbuf` returns EOF instead of erroring
(`pg_fts_am_scan.c:58`), and the block-payload bounds check treats a recycled
page as end-of-chain (`pg_fts_am_scan.c:2856-2871`), on the stated contract that
a stale read yields a *bounded wrong result, not a crash*, because the generation
re-check will catch it.

**That contract breaks under partitioning.** The guard's guarantee is "the whole
candidate set was generated within one generation epoch". With W workers each
guarding its own slice, worker 3 can complete in epoch 5 while worker 6 completes
in epoch 6 — every worker individually passes its guard, and the union is a
result from no single consistent snapshot. That is exactly the stale-read case
the EOF-tolerance was designed to let the guard clean up, and now nothing cleans
it up: a worker that hit a recycled page truncated its slice silently and
reported success.

The fix is not hard but must be explicit: **the leader reads the generation
once, passes it to all workers, each worker verifies it before and after its
slice, and the leader retries the entire parallel scan if any worker reports a
mismatch.** Per-worker retry is wrong — an epoch-consistent union needs a global
epoch. In `amcanparallel` terms the generation belongs in the AM's shared area
alongside the partition cursor. This is a genuine design obligation, not
boilerplate, and it is the kind of thing that produces an intermittently-wrong
top-k under a merge soak if skipped. The project already has the soak harness to
catch it (`bench/data_soak_bench`, and the 90 s concurrent merge/vacuum/6-reader
soak described at `CHANGELOG.md:191-193`).

### 5.2 The maintenance lock: no new deadlock, but a new stall

`bm25_maintenance_lock` is a heavyweight page lock on the metapage block
(`pg_fts_am.c:5422-5426`), taken blocking by explicit maintenance
(`pg_fts_am.c:5746`, `pg_fts_am.c:6046`, `pg_fts_am.c:6104`, and vacuum cleanup
`pg_fts_am.c:5965`) and conditionally by the insert-time tiered merge
(`pg_fts_am.c:5234`). **Scans never take it** — they rely on the generation guard
instead. So workers add no lock-ordering hazard.

One behavioural change worth noting: workers inherit the leader's lock group, so
a lock the leader holds is not self-blocking, but a *maintenance* backend now
waits behind W readers' buffer pins rather than one reader's. Merge latency under
read load gets worse in proportion to W. Not a correctness issue.
**Unverified:** whether any pg_fts scan path can be reached while the leader
holds the maintenance lock (that would be a group-lock deadlock risk). I found no
such path — `fts_merge`/`fts_vacuum` do not scan — but I did not audit
exhaustively.

### 5.3 Buffer pins are per-worker and that is fine

Every scan read is pin → `BUFFER_LOCK_SHARE` → copy → `UnlockReleaseBuffer`
within one function: `wand_load_block` (`pg_fts_am_scan.c:2810`, released
`pg_fts_am_scan.c:2907`), `wand_skip_blocks` (`pg_fts_am_scan.c:3115-3117`),
`bm25_doclen_cursor_load_page` (`pg_fts_am.c:2402`, released
`pg_fts_am.c:2456`). **No pin is held across a worker boundary or a
`CHECK_FOR_INTERRUPTS`** — the interrupt checks are explicitly placed where no
lock is held (`pg_fts_am_scan.c:2833`, `pg_fts_am_scan.c:3105`). Block payloads
are `memcpy`'d into palloc'd `blkbuf` precisely so nothing points into a page
after unlock (`pg_fts_am_scan.c:2874-2875`, and the same reasoning is recorded as
a rejected alternative in `bench/NOTE_PROFILE_COMMON_TERM_2026-09-06.md`:
"holding a pointer into the page after `UnlockReleaseBuffer` would be a
use-after-unpin bug"). Workers each keep their own private buffers.
**This part of the codebase is already parallel-ready.** Shared buffer contention
on hot pages rises with W but that is normal.

### 5.4 Relcache and reloptions

`rd_amcache` holds the doclen directory as one chunk keyed by generation
(`pg_fts_am.c:2241-2281`), satisfying the "pfree'd wholesale on relcache
invalidation" contract that 1.5.5 violated (`CHANGELOG.md:184-187`). Each worker
has its own relcache, so each builds its own copy — correct, but the cost noted
in §1.2. All SQL functions are already `PARALLEL SAFE` (33 occurrences in
`pg_fts--1.5.10.sql`, including `fts_distance` at line 326 and `fts_match` at
137), so no catalog change is needed.

---

## 6. PostgreSQL mechanism: `amcanparallel` vs parallel CustomScan

### 6.1 What `amcanparallel` requires

Currently all off: `amcanparallel = false` (`pg_fts_am.c:6261`), and the three
hooks NULL (`pg_fts_am.c:6295-6297`). Setting them requires:

- **`amestimateparallelscan(Relation, nkeys, norderbys) -> Size`**
  (`amapi.h:217`). Returns the AM's private shared-area size, appended after
  `ParallelIndexScanDescData` (`indexam.c:490-494`). For pg_fts: partition
  cursor / next-range counter, worker count, the leader's generation snapshot
  (§5.1), and a mismatch flag. ~64 bytes.
- **`aminitparallelscan(void *target)`** (`amapi.h:221`). Called once in the
  leader (`indexam.c:549-556`). Zero the counters, store the generation.
- **`amparallelrescan(IndexScanDesc)`** (`amapi.h:224`). Reset for a re-scan
  (`indexam.c:566-576`) — needed for a parallel KNN under a nested loop.
- **Coordination.** Workers attach via `index_beginscan_parallel`
  (`indexam.c:578`), reached from `ExecIndexScanInitializeDSM`
  (`nodeIndexscan.c:1694-1738`) and `...InitializeWorker`
  (`nodeIndexscan.c:1761`). The AM finds its area at `ps_offset_am`
  (`indexam.c:551-555`). nbtree is the only core example
  (`nbtree.c:136`).
- **Planner.** `create_index_path(..., partial_path=true)` is called when
  `amcanparallel && rel->consider_parallel` (`indexpath.c:984-1006`), and
  `cost_index` sets `parallel_workers` via `compute_parallel_worker`
  (`costsize.c:775-789`), zero-workers paths being discarded
  (`indexpath.c:1004-1007`). Two gates matter: `min_parallel_index_scan_size`
  defaults to 512 kB (`guc_tables.c:3735`) — the 1421 MB index clears it easily —
  and `max_parallel_workers_per_gather` defaults to **2**
  (`guc_tables.c:3624`), so out of the box users get the W=2 row of the table
  (~20 ms), not W=8. `bm25_costestimate` would need a parallel-aware branch; the
  ordering branch at `pg_fts_am.c:6136-6157` is currently hand-tuned to make a
  small LIMIT win, and the note about worker-launch fragility means **the cost
  model must be verified to actually produce workers**, which is what silently
  failed last time.

### 6.2 The real obstacle: the ordering path is a batch engine wearing a cursor costume

`amcanparallel` assumes workers *stream* tuples that Gather Merge combines
(`allpaths.c:3115-3127`). pg_fts's ranked path does the opposite: the first
`bm25_gettuple` call computes the entire top-k into scan state, then hands rows
out one per call (`pg_fts_am_scan.c:1449-1479`); on exhaustion it **re-runs the
whole WAND from scratch with a 4x larger k** (`pg_fts_am_scan.c:1489-1516`),
because a KNN AM must be able to return every match in score order and must not
impose its own ceiling (`pg_fts_am_scan.c:1494-1508`). Growth stops only at
`bm25_query_maxhits` (`pg_fts_am_scan.c:1466`).

Consequences:

- Each worker computes a full local top-k on its slice, then streams — which is
  fine for Gather Merge, since each worker's output is score-ordered and GM
  merges ordered streams. **This part actually composes well.**
- But the **adaptive-k regrow becomes a global operation.** If the executor pulls
  past k, every worker must independently regrow and recompute. Coordinating "all
  workers now use k=400" through the shared area, mid-scan, with each worker
  already positioned, is the ugly part. The alternative — let workers regrow
  independently — is *still exact* (each worker's local top-k' ⊇ its local top-k),
  but wastes work asymmetrically. Either way it is state that
  `ParallelIndexScanDesc` was not designed to carry.
- There is nothing to partition dynamically. nbtree's shared area is a *page
  cursor*: workers grab the next leaf page, so imbalance self-corrects. pg_fts
  would use a **static docid partition** (no random access into a posting chain,
  §3.2), so the shared area is a range allocator over a precomputed split, and a
  slow worker cannot be helped by a fast one. That is a meaningfully worse fit
  than nbtree's, and it is inherent to gap-encoded singly-linked posting chains.

### 6.3 CustomScan: don't

`pg_fts_customscan.c` has the machinery (COUNT pushdown, `create_upper_paths_hook`
at line 416 region; the file header at lines 8 and 11 still says "later stages
add a parallel ranked top-k CustomScan" and mentions the ranked
`set_rel_pathlist_hook` — a **stale comment left by the reverted work**, since no
`set_rel_pathlist_hook` is installed today: `grep` finds only that comment,
line 11). But `bench/NOTE_PARALLEL_RANKED.md` records that this path was built
and that **launching a parallel context from inside `ExecCustomScan` fell back to
serial on EC2 with 0 workers**, which is precisely how a CustomScan differs from
a partial path: it must create its own `ParallelContext` rather than being run
*by* the executor's Gather. The note also flags that a serial ranked CustomScan
is redundant with the existing `amgettuple` ordering scan at identical speed —
~400 lines for a second code path with no benefit.

**Verdict: if this is done, `amcanparallel` + Gather Merge over the existing
ordering scan is the only sane mechanism.** The prototype's own retrospective
says the same. That is also the version that fixes the ~40% serial visibility
tail, because each worker emits *visible* ranked rows through the normal
executor path rather than shipping candidates to a leader that does visibility
alone.

---

## 7. Effort estimate

Assuming the `amcanparallel` partial-path route.

| area | files | scope |
|---|---|---|
| AM hooks + shared area | `pg_fts_am.c` (flag `:6261`, hooks `:6295-6297`), `pg_fts_am.h` | new `BM25ParallelScanDesc` (range allocator, worker count, generation snapshot, mismatch flag) |
| scan-side partitioning | `pg_fts_am_scan.c` | `BM25ScanOpaqueData` (`:109`) gains parallel state; `bm25_beginscan` (`:1286`) / `bm25_rescan` (`:1313`) / `bm25_gettuple` (`:1410`); range acquisition; **epoch-consistent generation protocol (§5.1)** |
| range computation | `pg_fts_am_scan.c` | derive W docid boundaries from heap size or df; balance heuristic |
| adaptive-k coordination | `pg_fts_am_scan.c:1489-1516` | the ugliest part (§6.2) |
| cost model | `pg_fts_am.c:6121-6167` | parallel-aware branch; **must be validated to actually produce workers** |
| tie determinism | `pg_fts_am_scan.c:2682` | break ties on TID so `expected/*.out` stays stable (§4) |
| tests | `sql/`, `expected/`, `bench/` | partition-invariant test (parity alone is insufficient, §4); parallel==serial byte-diff; merge/vacuum soak for §5.1 |
| stale comment cleanup | `pg_fts_customscan.c:8,11` | mentions a ranked CustomScan / `set_rel_pathlist_hook` that no longer exists |

**Size:** ~600-900 lines across 4 files, plus tests. **Risk: high**, for
reasons that are mostly *not* about writing the code:

- The reverted attempt failed on **worker launch**, not algorithm. An
  `amcanparallel` path is launched by the executor's Gather rather than by the
  node itself, which is the specific fix — but "the planner must be persuaded to
  produce a parallel KNN path with a hand-tuned cost function" is the same class
  of fragility, and it fails *silently* (serial result, no error).
- No core AM combines `amcanorderbyop` with `amcanparallel`
  (`gist.c:67`/`spgutils.c:52` have orderbyop but `amcanparallel = false`;
  `nbtree.c:136` has parallel but not orderbyop). **pg_fts would be the first**,
  with no reference implementation and no core test coverage for the
  combination. That is a genuine unknown-unknowns surface.
- §5.1 (epoch-consistent generation) is a correctness obligation whose failure
  mode is an intermittently-truncated top-k under concurrent merge. Easy to get
  wrong, hard to notice.
- The measurable payoff is **20 ms at the default `max_parallel_workers_per_gather = 2`**,
  against 36 ms today and 2.1 ms for the competitor.

---

## 8. Comparison to impact-ordered / tiered postings

| | parallel scan | impact-ordered postings |
|---|---|---|
| best case | 36 → ~8-12 ms (W=8), ~20 ms at default W=2 | asymptotically O(k), i.e. ~2-4 ms — *if* it prunes |
| does it prune? | n/a (divides work) | **DISPROVEN on this corpus** |
| exactness | exact (§4) | exact for single-term; conflicts with docid-ordered intersection |
| format change | none | yes; new layout, likely a second one |
| index size | unchanged (1421 MB, best in field) | `bench/NOTE_IMPACT_ORDERING.md` measured **~3% larger** for the weaker skip-directory variant |
| breaks | nothing | docid ordering that `count(*)` / AND / phrase / prefix rely on |
| CPU efficiency | 38-54% (wastes cores) | improves absolute work |
| risk | high (§7) | high, and **already measured not to work** |

**Impact ordering is the worse bet, and not because it is harder — because it has
already been measured to fail on this corpus.** `bench/NOTE_IMPACT_ORDERING.md`
built the impact-ordered block skip directory and found `year` visited **5,282 of
5,296 blocks (99.7%)** before early-stop, `hungary` 170 of 173 (98%), because
within one term the per-block impact bounds cluster in a razor-thin band (idf is
constant across blocks, and thousands of blocks each contain some high-tf doc).
`bench/NOTE_WAND_PRUNING_2026-09-04.md` then explains why from first principles
and closes the door harder: the block-max bound is **already exactly tight**
(measured TRUE block max equals the current bound to 4 decimals on every band),
the threshold is healthy at ~12% below it, and 8x finer granularity moves the max
only 3.7-4.6% — still above the threshold in every band.

The stronger variant (reorder the postings themselves, not just a directory)
is not literally disproven — the notes are careful about that — but it must
overcome the same flat impact plateau that killed the directory, and it costs the
docid ordering that `count(*)`'s dictionary-df fast path
(`pg_fts_am_scan.c:4229`, exact `count(*)` at 2.20 ms, fastest in the field),
AND, phrase, and prefix all depend on. It would mean a **second posting layout**
for pure-ranked single-term queries — the notes say as much — trading away
best-in-field index size for a lever whose weaker form measured zero.

**So: parallel scan is the better bet of the two.** That is a statement about the
alternative, not an endorsement. Both are poor. The honest ranking is:

1. **Re-profile 1.5.10 with `perf`** (hours, zero risk). The 39/43 split is
   unverified (§1.0) and everything downstream depends on it.
2. **Attack the doclen path for high-df terms** if it really is 43%. Options
   worth costing: reviving inline doclen (v3 style) for high-df terms only —
   the dual-read machinery already exists per segment
   (`pg_fts_am.h:91-93`, `has_doclen_col` at `pg_fts_am_scan.c:4035`,
   `wand_contrib_cur` branching at `pg_fts_am_scan.c:3024-3026`) — which would
   remove sidecar probes entirely for exactly the query shape that is slow, at a
   size cost proportional to high-df postings only. **Unverified and not
   analyzed here; flagged as the direction the profile points at.** This helps
   every band, needs no new concurrency reasoning, and costs no CPUs.
3. **SIMD FOR-unpack**, already scoped at ~5-8% whole-query in
   `bench/NOTE_FORMAT_V3_PROFILE.md`.
4. Parallel scan — only if a field report demands wall-clock on common terms and
   idle CPUs are available.
5. Impact-ordered postings — not without new evidence.

And the framing question `bench/NOTE_WAND_PRUNING_2026-09-04.md` already raised
should be answered before any of 2-5: the affected shape is "rank a term
appearing in a third of the corpus", a stopword-like query most applications do
not issue. pg_fts is **fastest in the field on exact `count(*)`, smallest index,
and competitive on rare/AND/prefix** (`ROADMAP.md:267-276`). Spending 900 lines
and a first-of-its-kind AM capability on one adversarial benchmark row deserves a
user asking for it.

---

## 9. Open questions

1. **What is the actual 1.5.10 profile?** The 39/43 split is a reconstruction
   (§1.0). One `perf` run settles it and gates everything else.
2. **What does `bm25_doclendir_cache` cost per worker?** (~17k header-only page
   reads, per backend, per query.) If it is >1 ms it eats a large fraction of the
   projected win. **Unverified**; measurable with a cold-relcache timing.
3. **What is real worker startup on the bench rig?** I assumed 2 ms
   (**unverified**). At 3+ ms, W=8 stops being worth it over W=4.
4. **Will the planner actually produce a parallel KNN path?** No core AM combines
   `amcanorderbyop` with `amcanparallel`, and the last attempt failed exactly
   here (0 workers, silent serial). Worth a throwaway spike — set the flag, stub
   the hooks, see whether `EXPLAIN` shows Gather Merge over a parallel index scan
   — **before** writing any partitioning logic. Cheapest possible de-risking of
   the thing that actually killed the last attempt.
5. **How is adaptive-k coordinated across workers?** (§6.2) Independent regrow is
   exact but wasteful; coordinated regrow is shared mutable mid-scan state. No
   good answer yet.
6. **Does anything reach a scan while holding `bm25_maintenance_lock`?** I found
   nothing, but did not audit exhaustively (§5.2). A group-lock deadlock would be
   a nasty surprise.
7. **Is there a real workload behind this?** ROADMAP 7 says it "underpins the
   flat common-term latency described in #4"; #4a's own conclusion after
   profiling was that the premise was wrong twice over. No field report is cited
   anywhere in the tree.
8. **Would the doclen-for-high-df-terms idea (§8 item 2) actually work?**
   Not analyzed. It is the direction the profile points at and it is a smaller
   change than parallelism, so it should be costed before parallel scan is.
