# Known-issue investigation: Findings 3 and 4 from 1.7.0

**Date:** 2026-09-14
**Host:** r6id.8xlarge (32 vCPU / 247 GB / 1.7 TB NVMe), PG 17.10, local NVMe
**Corpus:** field shape — 1,660 terms/doc, vocabulary scaled to hold avg df ≈ 48
**Raw:** `bench/data_known_2026-09-14/diag.log`

Two known issues were shipped with 1.7.0. One is now **disproven** (my published claim was
wrong), the other is **confirmed and worse** than reported, with the cause still unknown
after four failed hypotheses.

---

## Finding 4 — DISPROVEN. My 1.7.0 release note was wrong.

I published that `bm25_free_page` emits one WAL record per page, that this cost ~14 ms/page,
and that it "needs WAL batching". Measured directly:

```
fts_vacuum rc=0 elapsed=46s pages 8728504->41587 size=324MB nseg=1
  per-page: 0.005 ms across 8,686,917 freed pages
```

**8.69 million pages freed in 46 seconds — 0.005 ms/page, ~2,800× cheaper than I claimed.**
A second run: 7,912,288 → 30,330 pages in 33 s. There is no per-page WAL problem.

**Where my number came from, and the lesson.** The 113-minute run was on an index that had
already hit the `pd_lower` allocation bug repeatedly (8 such errors in that server log), so
it was operating on a damaged, heavily fragmented state. `gdb` showed the backend *inside*
`bm25_free_page`, and I turned "this is where it is" into "this is why it is slow". A stack
sample tells you the location, not the bottleneck; I needed a rate, and a rate is what
disproves it.

**Action: the 1.7.0 known-issue entry is retracted in the CHANGELOG.** No code change.

---

## Finding 3 — CONFIRMED, and 210× not 45×. Cause still unknown.

Per-batch measurement, 5,000 docs per batch, no maintenance between batches:

| batch | index MB | nsegments |
|---|---|---|
| baseline | 613 | 1 |
| 1 | 5,374 | 8 |
| 2 | 11,015 | 8 |
| 3 | 17,331 | 8 |
| … | … | 8 |
| 10 | 61,814 | 8 |
| **after one `fts_vacuum`** | **236** | 1 |

**~5.6 GB per 5,000 documents, with `nsegments` pinned at 8**, and a single later
`fts_vacuum` recovering **210×**. The space is therefore freed-but-never-reused, not live.
A 40k-doc run reached 68,191 MB → 324 MB. This is worse than the 45× I reported in 1.7.0.

### Four hypotheses, all killed

1. **One-doc segments accumulating** (oversized docs each becoming their own segment) —
   killed by reading the code: `BM25_MAX_SEGMENTS = 128` and the insert path forces a merge
   when the directory fills, so 50k segments cannot exist.
2. **128-segment merge cycling** rewriting the whole index ~390 times — plausible but not
   what the data shows; `nsegments` sits at 8, not oscillating to 128.
3. **Freed pages rejected as unrecyclable** by `bm25_page_recyclable`'s XID gate — killed by
   instrumentation: `probe=0 reject=0`. The free-list scan is never *reached*, so nothing is
   being rejected.
4. **Loop-wide `bm25_alloc_extend_only`** making the merge skip the free list entirely —
   this one I implemented (scoping extend-only per merge instead of across the loop, with a
   properly owned `alloc_begin`/`alloc_end` pair). Result: **byte-identical growth**
   (5374 / 11015 / 17331 / 24544 in both arms). Not the cause. **Reverted, not shipped.**

Hypothesis 4's first attempt also *broke* the index — it read `bm25_lowfree_*` without
owning that state, handing out garbage block numbers. `t/007_segment_cap.pl` caught it
(`ERROR: could not open file ... target block 829694001: previous segment is only 527
blocks`). That test earning its keep is the one unambiguously good thing in this sequence.

### What a fifth attempt must do differently

Stop reasoning about the allocator and **measure where blocks are allocated**: a counter on
each of `bm25_new_buffer`'s three outcomes (low-bias reuse / FSM reuse / `P_NEW` extend),
reported per merge. I built that instrumentation twice and lost it twice to my own
edit-chain mistakes, and once to `log_min_messages = warning` silencing `elog(LOG)` — so:
**set `log_min_messages = info` in the harness, and verify the counters are present in the
shipped `.so` before trusting a run** (`grep -c PGFTSDIAG` on the source that was actually
tarballed).

---

## Shipped from this session

**Generalized the `pd_lower` guard to every read site.** 1.7.0 fixed the dict walk in
`merge_source_load_page`; auditing the siblings found **eight** read sites forming
`page + pd_lower` from unvalidated on-page data, including `bm25_free_segment`'s two walks
and the doclen and posting readers. All now route through one helper,
`bm25_page_data_end()`, which validates in the integer domain (forming the pointer at all is
UB for an absurd value — the fuzz target caught that in 1.7.0) and returns an empty range
for anything out of bounds, so callers degrade to "nothing to read".

This is the same defect class as the 1.7.0 P0 that made indexes permanently unvacuumable,
and 1.7.0 only fixed one instance of it.

## Honest status

- Finding 4: **not a bug.** Retracted.
- Finding 3: **confirmed, worse than published, cause unknown**, four hypotheses eliminated,
  next measurement specified. No unproven fix shipped.
