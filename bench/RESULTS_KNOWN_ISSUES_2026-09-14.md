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


---

# The measurement, and a 31% mitigation (2026-09-14, later same day)

Ran the measurement specified above — a counter on each of `bm25_new_buffer`'s outcomes,
reported through a SQL function so `log_min_messages` could not silence it.

## First: my `probe=0 reject=0` reading was a harness artifact

The per-batch tallies all came back zero while the index grew 5 GB per batch, which I
briefly read as "`bm25_new_buffer` is never called". It is called constantly. **The counters
are per-backend statics, and every `psql -c` is a new backend**, so each batch read a fresh
backend's zeros. Re-running the insert and the counter read *in one session*:

```
 50 docs: ext= 1181 ( 23.6/doc) norecyc= 785 reuse=0
100 docs: ext= 2539 ( 25.4/doc) norecyc=1521 reuse=64
200 docs: ext= 5924 ( 29.6/doc) norecyc=3169 reuse=16
```

That also means **hypothesis 3 was right all along** and I discarded it on the same
artifact. Three harness self-owns in this investigation (`%%` in SQL, `log_min_messages`,
per-backend statics), each of which produced a confident wrong reading.

## What is actually happening

**23–30 index pages extended per document, linear**, against roughly 2 pages of real
postings — a ~12–15× write amplification with page reuse at ~0.3%.

`norecyc` (3,169 of 5,924) is the binding constraint: freed pages **are** found and then
**rejected** by `bm25_page_recyclable()`, because the pages were freed by the inserting
transaction itself and `GlobalVisCheckRemovableXid()` cannot yet clear them. That gate is
correct and must stand — its comment records a real SIGSEGV from bypassing it (a concurrent
reader mid-copy of a livedocs blob). So **in-transaction reuse is impossible by
construction**, and the only available lever is to rewrite less often.

The rewrites come from write amplification at the smallest possible unit: at 1,660
terms/doc every document exceeds one pending page, so each one mints a **one-document
segment**, and the eager insert-time merge immediately folds it in — one document in, a
whole level-0 run rewritten out.

## The change

Gate the insert-time merge on there being `BM25_MERGE_FANOUT` small runs waiting, instead
of merging after every insert. Below that threshold the leveled compactor would find no
level over capacity and be a no-op anyway, so this skips work without changing behaviour.

| | before | after |
|---|---|---|
| growth over 6 × 5,000-doc batches | 31,386 MB | **21,723 MB** |
| peak index size | 31,537 MB | **21,874 MB** |
| size after one `fts_vacuum` | 124 MB | **124 MB** (identical) |
| nsegments during churn | 8 | 7–8 |

**31% of the growth removed**, with the final compacted size byte-identical.

## Verifying the safety property I put at risk

The eager merge exists because a field deployment went 8 → 128 segments in ~1 h and then
could neither merge nor VACUUM. Deferring merges risks exactly that, so it was measured
under the worst case for segment minting — **one row per transaction, 4,000 transactions**:

```
round8  (800 rows):  nseg=7  max=12
round40 (4000 rows): nseg=14 max=15
SEGCAP max_nsegments=15 (hard cap 128) -- OK
```

Max 15 against a cap of 128, index 124 → 154 MB. `t/007_segment_cap.pl` now asserts
`<= 64` rather than `<= 128`, because a bound at the hard cap would only fail once the
index was already in the unrecoverable state.

## Honest status: mitigation, not fix

Growth is still ~3.7 GB per 5,000 documents, and `fts_vacuum` is still required after bulk
ingest. Eliminating it means moving the merge out of the inserting transaction so its freed
pages can pass the XID gate — a design change, not a release-day edit. The known issue stays
open, now with its mechanism measured rather than guessed.
