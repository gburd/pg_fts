# Code review: the "per-worker output fragmentation" defect (2026-09-09)

Independent code-reading analysis of ROADMAP item 3a, done without coordination
with the empirical agent. Read-only review of tag v1.6.0 (`d0ad670`). Every
claim about existing behaviour is cited `file:line`; everything I could not
settle from the code is marked **unverified**.

---

## THE OBVIOUS HYPOTHESIS IS WRONG

> "Each participant packs its own pages, so every per-participant flush leaves a
> partially-filled last page."

**This cannot be the cause. It is off by two to three orders of magnitude, and
the code says so arithmetically, not speculatively.**

A segment writes at most four page chains: the shared posting chain
(`bm25_write_postings`, pg_fts_am.c:1604), the dictionary chain
(`bm25_write_dictionary_iter`, pg_fts_am.c:2590), the dict block index
(pg_fts_am.c:2695), and the v4 doclen sidecar (`bm25_write_doclen_sidecar`,
pg_fts_am.c:1817). Each chain leaves **at most one** partially-filled page,
because each writer advances to a new page only when the next item does not fit
(pg_fts_am.c:1757-1760, 2617-2619, 1867-1869) — never early, never on a term
boundary, never on a flush boundary. Critically, all terms in a segment share
**one** posting chain (pg_fts_am.c:1559-1564, and the write loop at
pg_fts_am.c:2841-2857 opens `pw` once for the whole segment), so a rare term
costs bytes, not a page.

So the entire per-segment partial-page slack is bounded by ~4 x 8 KB = 32 KB.
Even at the hard directory cap of `BM25_MAX_SEGMENTS = 128` (pg_fts_am.h:96)
that is **4 MB of slack for the whole index**. The measured deltas are
**781 MB** (1 GB build), **1,093 MB** (256 MB build) and **1,623 MB** (parallel
merge). The hypothesis is short by a factor of ~200-400.

The project's own later measurement agrees and I did not need it to reach this:
`README.md:322` records live pages averaging **98.8% full** after a build.
Packing density is not the problem. Whatever the extra bytes are, they are not
inside pages.

---

## Most likely root cause: freed-but-untruncatable pages, i.e. transient
## write-before-free residue positioned above live data

**Confidence: high (~85%) for the merge case, high (~80%) for the build case.**
Same mechanism in both; the *reason* the parallel path leaves more of it differs
slightly between them.

The measured numbers are `pg_relation_size` — file length, not live bytes. Three
facts in the code make file length a poor proxy for index size, and make the
parallel path systematically worse on that proxy:

1. **A merge writes its output before freeing its inputs**, for crash safety
   (`bm25_merge_selected` writes at pg_fts_am.c:3827, then swaps the metapage and
   only then calls `bm25_free_segment` at pg_fts_am.c:3910-3912). Freed pages go
   to the FSM (`bm25_free_page` -> `RecordFreeIndexPage`, pg_fts_am.c:3538), which
   does not shrink the file.

2. **Merges deliberately allocate extend-only**, so output never reuses the
   just-freed input pages: `bm25_alloc_extend_only = true` in `bm25_merge_all`
   (pg_fts_am.c:4202) and `bm25_merge_segments` (pg_fts_am.c:4674). The comment at
   pg_fts_am.c:4665-4672 gives the reason — recycling a freed block while another
   reader's `nextblk` chain still threads it is a wrong read or SIGBUS. So each
   merge pass *appends* its whole output above everything else.

3. **Truncation can only reclaim a contiguous free tail.**
   `bm25_truncate_free_tail` walks down from EOF and `break`s at the first live
   block (pg_fts_am.c:4446-4449). With the newest output at the top of the file,
   every freed page beneath it is unreachable until a compaction pass relocates
   live data downward — which only `bm25_vacuum_compact` (pg_fts_am.c:4522) does.

Now the parallel-specific part. `bm25_merge_all(index, true)` runs
`bm25_merge_all_parallel` **and then still runs the full serial collapse loop**
(pg_fts_am.c:4191-4196 followed by the unconditional loop at
pg_fts_am.c:4202-4257). The parallel pass is not an alternative to the serial
collapse — it is an **extra pass in front of it**. `bm25_merge_one_group` merges
each group's sources into a new segment (pg_fts_am.c:4011) and the leader frees
the sources (pg_fts_am.c:4158-4162), then the serial loop reads those W new
segments and writes the final single segment on top of them again.

That is a second full-volume write of the entire index, appended, whose inputs
become freed-but-buried pages. The arithmetic lands almost exactly:

| | file growth over the 7,185 MB input | as a multiple of the 1-segment size (1,421 MB) |
|---|---|---|
| serial (s1/s2) | 1,421 MB | **1.00x** — exactly one output |
| W=1 (h1) | 1,552 MB | 1.09x |
| W=3 (g1/g2) | 1,623 MB | 1.14x |

The parallel runs write roughly one extra *intermediate* volume beyond the serial
run's single output. It is not 2.00x because the intermediate segments are
themselves compacted (tombstone-free, merged) and because the serial tail merges
W inputs rather than 8. Timing corroborates: g1 total 333.6 s of which the
logged final serial pass is 225.9 s, leaving ~108 s for the parallel pass
(matrix.log g1); h1 333.5 s with a 214.8 s final pass, leaving ~119 s. The
serial-only runs' single logged pass is 228.1 s and the total is 230.8 s — i.e.
**serial does one pass, parallel does that same pass plus an extra ~110 s one.**

The 1.45x slowdown is not mysterious coordination overhead. It is one extra full
pass over the data, and the extra pass writes the extra bytes.

---

## Does this explain the three facts the simple hypothesis could not?

### W=1 == W=3 on merge — YES, cleanly

Under the partial-page hypothesis, cost scales with participant count, so W=1
should be ~1/3 of W=3's penalty. It isn't. Under mine, W is nearly irrelevant:
the penalty is *one extra pass over the whole index*, and a pass costs the same
total bytes however many participants split it. W only changes the number of
intermediate segments (`ngroups = min(request+1, nsrc)`, pg_fts_am.c:4077-4080)
and hence the fan-in of the final serial merge — a second-order effect.

The tiny W=1-vs-W=3 difference (1,552 vs 1,623 MB) even has the right sign and
magnitude: at W=1, `ngroups=2` (one is the leader), so the extra pass merges the
8 sources into 2 and the final pass merges 2. At W=3, `ngroups=4`, so the final
pass merges 4 — slightly less compacted intermediates, slightly more residue.
The DEBUG1 lines confirm exactly this: h1 logs "merging 2 of 2", g1/g2 log
"merging 4 of 4", serial logs "merging 8 of 8" (matrix.log).

### 2 GB makes it nearly vanish on build — YES, and this is the decisive test

This is where the two hypotheses separate hardest, because at 2 GB **both build
configurations already produce `nsegments = 1`** (item3b.log rows: 2GB/0 and
2GB/4 both `nseg_after_build 1`, `merge_s 0.0`). So does 1 GB (both rows
`nseg=1`), yet 1 GB still shows a 781 MB delta and 2 GB shows 5 MB.

- Partial-page hypothesis: cannot distinguish 1 GB from 2 GB at all. Both end at
  one segment, so both have identical final partial-page slack. It predicts the
  same delta at both settings. **It is falsified by this row.**
- Mine: `nsegments = 1` is the *post-finalize* count, not the count the
  participants flushed. `bm25_build_finalize` (pg_fts_am.c:4292) runs
  `bm25_merge_segments` then `bm25_merge_all` (pg_fts_am.c:4312, 4337), and every
  merge appends. What matters is **how many segments the participants flushed
  before finalize**, because that determines how much merge volume gets appended
  and buried. At 2 GB, four participants each holding up to
  `2 * maintenance_work_mem = 4 GB` (`bm25_build_mem_ceiling`, pg_fts_am.c:449-459)
  need few or no mid-scan flushes — each may emit only its end-of-scan residual
  (pg_fts_am.c:4894 for a worker, 5099 for the leader). With ~4-5 segments to
  collapse, one cheap merge pass is appended. At 1 GB (2 GB ceiling) each
  participant flushes more often, so finalize has more and smaller segments to
  collapse — the tiered pass at pg_fts_am.c:4312 may fire, then the collapse at
  4337, appending more buried volume. It is a threshold in flush *count*, and
  2 GB crosses it. Consistent with the data; the exact flush counts are
  **unverified** (`elog(LOG)` at pg_fts_am.c:556-557 records them, but the
  captured logs do not include build LOG lines).

Note the doubling schedule (pg_fts_am.c:579-584) makes this sharper than linear:
the budget doubles every 8 flushes, so halving `maintenance_work_mem` more than
doubles the segment count in the low tiers.

### It affects merge as well as build — YES, because they share one writer

This was worth checking and the answer is that build and merge share the page
writer completely, contradicting the premise that they might be different code:

- Build: `bm25_write_segment` (pg_fts_am.c:2830) -> `bm25_write_postings`
  (pg_fts_am.c:1604) + `bm25_write_dictionary` (pg_fts_am.c:2773 ->
  `bm25_write_dictionary_iter`, 2590) + `bm25_write_doclen_sidecar` (1817).
- Merge: `bm25_merge_segments_streaming` (pg_fts_am.c:3296) -> **the same**
  `bm25_write_postings` (called at pg_fts_am.c:3441) + the same
  `bm25_write_dictionary_iter` (3475) + the same `bm25_write_doclen_sidecar`
  (3472).
- Both allocate through the same `bm25_new_buffer` (pg_fts_am.c:1168) and both
  init pages through the same `bm25_init_page` (pg_fts_am.c:1250).

The parallel merge path is not a different writer either:
`bm25_merge_group_to_seg` (pg_fts_am.c:3757) calls the identical
`bm25_merge_segments_streaming` (pg_fts_am.c:3775). The only thing the parallel
merge path adds is the partitioning and the metapage swap
(pg_fts_am.c:4025-4170).

So there is exactly one packing implementation in this extension. If packing
were the defect, serial would have it too — and serial doesn't. That is itself
strong evidence against the packing hypothesis and for an allocation/lifecycle
explanation, which is what both paths do share: extend-only append plus
write-before-free.

---

## Fixed per-segment overhead: real, but ~0.05% of the effect

- `BM25SegMeta` is 56 bytes (`BlockNumber`x5 + `double`x2 + `uint32`x3, with
  padding; pg_fts_am.h:80-94) and lives **inline in the metapage**
  (`segs[BM25_MAX_SEGMENTS]`, pg_fts_am.h:118). 128 x 56 = 7,168 bytes,
  pre-allocated in block 0. It **does not grow with segment count** — the array
  is fixed-size, written once by `bm25_init_metapage` (pg_fts_am.c:1389). Zero
  marginal cost per segment.
- Per-segment *page* overhead: the ~4 chain-tail partial pages discussed above
  (<= 32 KB) plus one `PageHeader` + `BM25PageOpaqueData` per page (24 + 8 bytes
  of a 8,192-byte page = 0.4%, identical serial and parallel, `bm25_init_page`
  pg_fts_am.c:1250-1259).
- `MAXALIGN` slack: per **item**, not per page —
  `MAXALIGN(sizeof(BM25BlockHdr) + sclen + poslen)` (pg_fts_am.c:1745),
  `MAXALIGN(sizeof(BM25DictEntry) + r.len)` (pg_fts_am.c:2611),
  `MAXALIGN(sizeof(BM25DoclenBlockHdr) + gapbytes + bcount)`
  (pg_fts_am.c:1863). Averages ~4 bytes/item and is **identical** for serial and
  parallel output of the same data, so it cannot produce a serial/parallel
  delta.
- One real per-segment cost that *does* scale: more segments means more
  dictionary copies of the same vocabulary, and the sidecar re-quantizes per
  segment. For 7.36M terms that is not trivial — but it is a *pre-finalize*
  cost, and all runs finalize to one segment with identical term counts
  (7,357,921 in every matrix.log run), so it cannot explain a difference in the
  *final* file. It does add to the buried-intermediate volume, which is the
  mechanism above.

Conclusion: fixed per-segment overhead is bounded at single-digit MB and is not
the effect. **Confidence: high** — this one is pure arithmetic on struct sizes.

---

## Would `fts_vacuum` reclaim it?

**Yes, essentially all of it — this is durable-looking but transient bloat.**
Confidence: high from the code; the project has since measured it (README.md:315-325,
4,406 -> 1,355 MB) which matches my reading, though I derived the mechanism
independently.

`bm25_vacuum_compact` (pg_fts_am.c:4522) exists precisely for this layout and its
header comment (pg_fts_am.c:4543-4570) describes the exact situation: live segment
sitting high, freed pages low, free region smaller than live, nothing truncatable.
Its two-phase vacate-then-pack:

1. **Vacate** — `bm25_compact_to_one(index, true)` (pg_fts_am.c:4593), extend-only,
   pushes live data onto fresh high blocks so the freed region below becomes
   contiguous and >= live size. File grows transiently.
2. **Pack** — `bm25_compact_to_one(index, false)` (pg_fts_am.c:4599) with
   `bm25_alloc_begin` (pg_fts_am.c:1139) handing out the lowest free blocks first
   (pg_fts_am.c:1176-1195), relocating live data to the front.
3. **Truncate** — `bm25_truncate_free_tail` (pg_fts_am.c:4604) now finds a
   genuinely contiguous free tail.

Two automatic triggers already cover it: `bm25_vacuumcleanup` invokes it when
>= 25% of the file is free (pg_fts_am.c:5980-5988), and `bm25_build` already calls
`bm25_truncate_free_tail` at the end of a build (pg_fts_am.c:5144) — which recovers
only the contiguous tail, hence the residual bloat the benchmark measured.

**The important consequence: every size number in both benchmark documents is a
pre-`fts_vacuum` file length, so the "17%/25%/19% larger index" figures measure
un-truncated transient residue, not durable index size.** The correct comparison
is serial-then-`fts_vacuum` versus parallel-then-`fts_vacuum`. My prediction is
that the delta collapses to near zero; **unverified**, and it is exactly what the
empirical agent should settle. One caveat: `bm25_index_is_compacted`
(pg_fts_am.c:4472) short-circuits the rewrite when there is one live segment and
free space below the last live block is under `max(nblocks/50, 8)` — so a
sufficiently-front-packed-but-bloated layout could skip the pass. Whether the
post-build layout trips that guard is **unverified**.

---

## Severity

**Space and time only. No correctness risk. Nothing depends on page fill
density.** Confidence: high.

Readers locate data by explicit pointers and lengths, never by assuming a page
is full:

- Posting reads follow `(firstposting, firstoffset)` from the dict entry and
  bound by `pd_lower`, walking `nextblk` across pages (`bm25_decode_term`,
  pg_fts_am.c:832-838, with `off = MAXALIGN(SizeOfPageHeaderData)` for
  subsequent pages at pg_fts_am.c:1058).
- Block advance is `(bh + 1) + bh->bytelen + bh->posbytelen`, MAXALIGN'd
  (pg_fts_am.c:1053-1054) — self-describing, fill-independent.
- Dict and sidecar scans bound on `pd_lower` the same way (pg_fts_am.c:1972,
  2409, 3068, 3622).
- `bm25_free_segment` walks dict entries by their own `termlen`
  (pg_fts_am.c:3627) and frees the shared posting chain once
  (pg_fts_am.c:3638-3639).

Correctness was also measured: all seven merge runs returned identical match
counts (matrix.log). The one adjacent risk is indirect — a partly-filled index
is a larger index, so a very large build could approach a disk limit it wouldn't
otherwise. Bounded and operationally visible.

Also worth flagging, and unrelated to fragmentation: **the `mpmw = 8` trap is
the more serious operability defect in this area.** `bm25_merge_all_parallel`
requests `min(max_parallel_maintenance_workers, max_parallel_workers)`
(pg_fts_am.c:4193-4194) and each worker only does work if
`ParallelWorkerNumber + 1 < ms->ngroups` (pg_fts_am.c:3987), where
`ngroups = min(request+1, nsrc)` (pg_fts_am.c:4077-4080). With 8 sources and
request 8, `ngroups = 8`, so worker 7 exits immediately — which explains 7 of 8
exiting fast but **not** all 8 producing a fully serial merge. The observed
~2 ms exit of *every* worker is not explained by this arithmetic and I cannot
resolve it from the code. **Unverified — worth its own investigation.** A
configuration knob that silently disables the feature it names is a trap
regardless of which path is faster.

---

## Recommendation: document; do not fix the fragmentation

Ranked, and I would stop at 2:

1. **Correct the published size claims first — they are measuring the wrong
   thing.** The +17/25/19% figures are pre-`fts_vacuum` file lengths dominated
   by transient residue. That correction is nearly done (README.md:181-189 and
   doc/pg_fts.sgml:590-609 already flag it UNDER REVIEW and README.md:315-325
   quantifies the reclaim); it needs the serial-vs-parallel *post-vacuum*
   comparison to close, and the `bench/DIAG_WORKER_FRAGMENTATION.md` those docs
   reference does not exist yet.

2. **Document that raising `max_parallel_maintenance_workers` makes `fts_merge`
   slower, and leave the merge code alone.** The reason is now specific and
   documentable rather than hand-wavy: `bm25_merge_all(index, true)` runs the
   parallel pass *in addition to* the serial collapse (pg_fts_am.c:4191-4257), so
   the parallel path is strictly more total work. That is a one-paragraph doc
   change with zero risk, in a code path that has already produced three
   concurrency-fix releases (1.5.5/1.5.6/1.5.7).

3. **Parallel build stays a genuine win** and needs no change: 464 s vs 523 s at
   1 GB, and the size difference is (predicted) reclaimable. Add "run
   `fts_vacuum` once after a large build" — already present at README.md:323-325.

The one non-doc change I would consider, and only if the empirical agent shows
the post-vacuum parallel-merge delta is still material:

4. **Make the extra pass not extra.** In `bm25_merge_all`, skip the serial
   collapse loop when the parallel pass already reduced the directory to one
   segment, or reduce W so the parallel pass lands on one group. Today the loop
   runs unconditionally. This is a ~5-line change at pg_fts_am.c:4196-4206
   (`if (didwork) { re-read meta; if (nsegments <= 1) skip; }`). But note it
   cannot make parallel merge *win*: the final combine is a single-backend write
   of one multi-GB segment, which the code comment at pg_fts_am.c:4180-4188
   already identifies as unparallelizable by any group partition, and the
   measurement agrees (the logged final pass alone is 214-226 s versus 228-231 s
   for the whole serial merge). Best case it becomes a tie. **Not worth the
   risk.**

What I would **not** do: touch `bm25_write_postings`, `bm25_new_buffer`, or the
flush-budget schedule. Pages are 98.8% full; there is no packing defect to fix,
and those are the three functions the concurrency-fix releases converged on.

Honest bottom line: **document the trade and leave the code alone.** The defect
as described in ROADMAP 3a — "per-worker output fragmentation" — does not exist
as a packing problem. What exists is (a) a measurement artifact from comparing
pre-`fts_vacuum` file lengths, and (b) a real but different inefficiency in
`bm25_merge_all`, which is doing two passes where serial does one.

---

## What a fix would touch, and its risk

If item 4 above is pursued anyway:

| Change | Site | Risk |
|---|---|---|
| Skip the serial collapse when the parallel pass reached 1 segment | pg_fts_am.c:4196-4206 | **Low-medium.** Pure control flow, no page-format or locking change. Needs a test that `fts_merge` still converges to `nsegments = 1` when the parallel pass leaves > 1 group. The failure mode is benign (leaves several segments = slower scans, not wrong answers). |
| Choose W so `ngroups` lands on 1 | pg_fts_am.c:4077-4080 | **Low**, but pointless — `ngroups = 1` means no parallelism at all, i.e. just don't take the path. |
| Reuse freed input pages for merge output instead of extend-only | pg_fts_am.c:4202, 4674 | **Do not do this.** The comment at pg_fts_am.c:4665-4672 documents that this is exactly the SIGBUS/wrong-read bug extend-only was introduced to prevent, and the recycle gate (pg_fts_am.c:3548-3583) is the other half of that fix. This is the code that produced 1.5.5/1.5.6/1.5.7. |
| Change flush granularity / budget schedule | pg_fts_am.c:488, 579-584 | **Medium-high, and misdirected.** The doubling cap exists because uncapped doubling drove a real 1.8M-doc build into swap death (pg_fts_am.c:562-577). Peak memory is `(workers+1) x ceiling`; lowering flush frequency raises peak memory per participant. Trading an OOM risk for a few MB of tail pages is a bad trade, and it isn't where the bytes are. |

Cheapest genuinely useful change is neither of these: **have `bm25_build`
optionally run the full `bm25_vacuum_compact` rather than only
`bm25_truncate_free_tail`** (pg_fts_am.c:5144), so a fresh index reports its real
size. Behaviour-only, no format change, no concurrency exposure (the comment at
pg_fts_am.c:5137-5143 establishes the backend is the sole writer with
`AccessExclusiveLock` and `indisready = false`). Cost is one extra rewrite of the
index at the end of a build, so it would have to be opt-in — which arguably makes
"just call `fts_vacuum` yourself" the lazier and better answer.

---

## What I could not determine from the code alone

1. **Actual flush counts per participant** at each `maintenance_work_mem`. This
   is the linchpin of my 2 GB explanation. `elog(LOG)` at pg_fts_am.c:556-557
   prints them per flush; the captured logs
   (`bench/data_gating_2026-09-09/item3b.log`) do not include server LOG lines.
   **Most valuable single thing to capture.**
2. **Post-`fts_vacuum` serial vs parallel sizes.** Every published delta is
   pre-vacuum. My prediction: near zero for both build and merge. If it is
   *not* near zero, my root cause is incomplete and the effect is something I
   have not found.
3. **Live-page counts per run** (live pages vs `pg_relation_size`), serial and
   parallel, to confirm the delta is entirely freed-untruncatable pages rather
   than genuinely more live pages. `pg_freespacemap` gives this directly.
4. **Whether `bm25_index_is_compacted` (pg_fts_am.c:4472) short-circuits the
   post-build vacuum.** If the guard trips, `fts_vacuum` may reclaim less than
   my analysis assumes.
5. **Why all 8 workers exit in ~2 ms at `mpmw = 8`.** The
   `ParallelWorkerNumber + 1 < ngroups` gate (pg_fts_am.c:3987) explains one
   worker, not eight. Separate defect, needs its own look.
6. **Whether the parallel pass writes *more* total bytes than an equivalent
   serial first pass would**, i.e. whether there is any real per-participant
   inefficiency on top of the extra-pass effect. My arithmetic (1.09-1.14x of
   one output volume) is consistent with "no", but it is inferred from three
   file-size numbers, not measured. Per-participant byte counters would settle
   it.
7. **Whether `maintenance_work_mem` is inherited by parallel build workers as
   the same absolute value** (each participant sizing its own budget from the
   GUC at pg_fts_am.c:430-436). I read the code as yes — each participant
   independently gets the full `mwm` — which is what makes peak memory
   `(workers+1) x 2 x mwm` as documented at pg_fts_am.c:576-578. Not verified
   against a running build.

---

# Lead verification of this review (2026-09-09)

I re-checked the load-bearing claims in the source rather than accepting them,
because this review's conclusion ("document, don't fix") closes a ROADMAP item.

**VERIFIED: the parallel pass is additive, not an alternative.** `pg_fts_am.c:4191`
runs `bm25_merge_all_parallel()` inside an `if (try_parallel ...)`, and on success
sets `didwork = true` and then **falls straight through** to the serial collapse
loop at `:4202` onward. There is no early return. So a parallel `fts_merge` performs
the parallel pass *plus* the same serial collapse a serial merge does. That is a
sufficient explanation for both measured effects at once: ~1.45x the wall-clock and
an extra pass's worth of freed-but-buried pages.

**VERIFIED: the freed pages are a deliberate safety property, not a leak.** The
comment at `pg_fts_am.c:4665-4672` states that merge output is allocated
extend-only specifically so that a committed merge's freed input pages cannot be
recycled as the *next* merge's output while in-flight read chains still thread
through them — otherwise "a wrong read or a SIGBUS". So post-merge bloat is the
price of a correctness guarantee, and `bm25_truncate_free_tail` reclaiming only a
contiguous tail (`:4446-4449`, which `break`s at the first live block from EOF) is
why it survives until a compaction pass moves live data down. This materially
changes how item 3a should be framed: the bytes are intentional, and the question
is only *when* they are reclaimed.

**RESOLVED: the `mpmw=8` mystery the review flagged as unverified.** The gate is
`ParallelWorkerNumber + 1 < ms->ngroups` (`:3987`), and `ngroups = min(request + 1,
nsrc)` (`:4077-4080`). Checking the actual DEBUG1 from the measurement run
(`bench/data_parallel_merge_2026-09-08/confirm8.log` and `matrix.log`), **every**
run — `mpmw=8` and `mpmw=3` alike — logs a single `merging 8 of 8 segments ... into
one`. There is no group split in the log at all, so the parallel pass found nothing
to partition and the workers correctly did nothing. The fast exits are the gate
working as designed, not a defect. What remains genuinely odd is only that we pay
worker launch/teardown for zero work, which is a cost-model wart rather than the
operability bug the review suspected.

**Assessment.** I agree with "document, don't fix" on the fragmentation framing, and
the review's arithmetic (4 MB of possible slack vs 781-1,623 MB measured) is
decisive against the hypothesis I gave the team. The one open question is still the
empirical post-`fts_vacuum` comparison: if the delta does not collapse to ~0, this
root cause is incomplete, and the review correctly listed that as its own
falsifier.

The `if`-fallthrough at `:4191` is worth a follow-up on its own terms regardless of
the size question — not to make parallel merge faster (the final combine is
single-backend by construction, per `:4665-4672`), but because *doing the work
twice* is indefensible even when the second pass is required. A ~5-line early
return after a successful parallel pass would at minimum stop us paying for the
parallel pass and then discarding its benefit.
