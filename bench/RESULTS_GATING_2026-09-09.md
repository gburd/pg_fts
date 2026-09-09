# Gating measurements on the shipped 1.6.0 build (2026-09-09)

Two measurements taken before starting any of the queued work, because the queued
work depended on numbers I had never actually captured. Both came back against the
plan.

Rig: EC2 r6id.4xlarge (16 vCPU, 128 GB, local NVMe), PostgreSQL 17.10, pg_fts
**1.6.0** (`extversion` confirmed), 2,188,038 Wikipedia articles, 1421 MB index,
`nsegments=1`, `shared_buffers=64GB`, warm.

## 1. `perf` on the shipped build — I had the split backwards

I had been quoting "candidates 39% / doclen 43%" for the common-term query. That
was never captured from a real run on the shipped build (see the correction in
ROADMAP 7). Measured now, all three bands:

| band | `load_page` | `lookup` | **doclen total** | `topk_candidates_range` | `wand_load_block` |
|---|---|---|---|---|---|
| rare (`slovakia`, df 10,875) | 64.4% | 4.5% | **68.9%** | 6.8% | — |
| mid (`hungary`, df 24,097) | 65.8% | 5.8% | **71.6%** | 6.0% | — |
| common (`year`, df 734,896) | 28.3% | 16.9% | **45.2%** | 37.2% | 6.4% |

**The doclen sidecar path is the dominant cost in every band**, and overwhelmingly
so for rare and mid (~70%). For common it is still the larger half (45.2% vs
37.2%).

This matters for ROADMAP 4a. The parallel-scan analysis
(`bench/PLAN_PARALLEL_SCAN.md`) computed its Amdahl ceiling from the old split, and
the note said the verdict was insensitive to which split was used — that holds, the
NO-GO stands. But the *direction of further work* changes: the target is
`bm25_doclen_cursor_load_page`, not the WAND driver.

Note what this does **not** say. 1.5.9's block-granular decode and 1.5.10's
`bm25_for_get` fix already attacked this function and produced real wins
(rare 1.7x, common 1.56x). What remains in `load_page` is the **gap-decode
prefix**: docids in a sidecar block are delta-encoded, so reaching an arbitrary
offset means walking from entry 0, measured at 60-82 entries per probe
(`bench/NOTE_PROFILE_COMMON_TERM_2026-09-06.md`). That is inherent to the format,
which is why the note concluded rare/mid were "at their floor". This profile
confirms the floor is high, not that there is an easy win left.

## 2. Item 3 sizing — the premise is false

ROADMAP 3 proposed giving each parallel-build worker a larger flush budget so a
build leaves ~1 segment per worker instead of many, shrinking the follow-on merge.
Swept `maintenance_work_mem` x `max_parallel_maintenance_workers`, recording
segments after build and the cost of the merge that follows:

| `mwm` | workers | build | nseg after build | index | merge | after merge |
|---|---|---|---|---|---|---|
| 64MB | 0 | 474.5 s | 8 | 7192 MB | 215.9 s | 8613 MB |
| 256MB | 0 | 367.0 s | 6 | 4373 MB | 223.1 s | 5793 MB |
| 256MB | 4 | 308.3 s | 6 | 5466 MB | 229.8 s | 6887 MB |
| **1GB** | **0** | 523.3 s | **1** | 4605 MB | **0.0 s** | 4605 MB |
| **1GB** | **4** | 464.4 s | **1** | 5386 MB | **0.0 s** | 5386 MB |
| **2GB** | **0** | 527.1 s | **1** | 4323 MB | **0.0 s** | 4323 MB |
| **2GB** | **4** | 360.1 s | **1** | 4328 MB | **0.0 s** | 4328 MB |

**At `maintenance_work_mem >= 1GB` the build already leaves `nsegments = 1` and the
follow-on merge is a 0.0 s no-op.** There is no fragmented-build problem to solve
at realistic settings; the item was scoped against 64MB-era behaviour. The default
`maintenance_work_mem` is 64MB, so the fix for a fragmented build is **raise
`maintenance_work_mem`**, which is documentation, not code.

**Second finding, and the more important one: parallel workers make the build
faster but the index bigger, every time.** 256MB: 367→308 s but 4373→5466 MB.
1GB: 523→464 s but 4605→5386 MB. That is the *same* per-worker output
fragmentation measured for parallel *merge* (19% bloat,
`bench/RESULTS_PARALLEL_MERGE_2026-09-08.md`) — so it is one defect showing up in
two places, not two coincidences. At 2GB the effect nearly vanishes
(4323→4328 MB), consistent with fragmentation being per-worker flush granularity.

## Consequences for the queued plan

- **Item 3: CLOSED as scoped.** Its premise does not hold at `mwm >= 1GB`. What
  survives is a *documentation* item (say that `maintenance_work_mem` governs
  post-build segment count, and that raising it to >= 1GB eliminates the merge) and
  a *real* code item: the per-worker fragmentation shared with parallel merge.
- **Item 4a: retargeted.** The cost centre is the doclen gap-decode prefix, not the
  WAND driver. Any further work is a sidecar *format* question (e.g. periodic
  absolute docids within a block to allow a mid-block start), which the earlier
  note sized at ~2x of a portion of the query. Still not obviously worth it, and
  now measured rather than assumed.
- **The one genuinely new, unblocked finding is the fragmentation defect.** It
  costs 19% on merge and up to 25% on build, appears at low-to-mid
  `maintenance_work_mem`, and nobody has looked at it. That is a better target than
  anything else in the queue.

## Process note

The first attempt at the item-3 sweep returned all zeros because a leftover
profiling backend of mine held a lock that deadlocked every `DROP INDEX`. Caught
because "build_s 0.0, nseg 1" for every row is not a plausible result. Re-run
clean after terminating it. Raw: `bench/data_gating_2026-09-09/`.

---

## Correction to 1.5.10's "at their floor" wording

1.5.10's CHANGELOG says rare and mid are "at their floor" and that a sidecar
format change (periodic absolute docids inside a block, to allow a mid-block
start) would be "worth at most ~2x of a portion of the query". **That understated
it**, because it was reasoned from the common-term profile where `load_page` is
only 28.3%. On rare and mid it is ~65%:

| band | total | `load_page` share | `load_page` time | if a mid-block start halved the prefix |
|---|---|---|---|---|
| rare | 5.89 ms | 64.4% | 3.79 ms | 3.99 ms → **1.47x** |
| mid | 10.64 ms | 65.8% | 7.00 ms | 7.14 ms → **1.49x** |

So the sidecar format change is worth roughly **1.5x on rare and mid** — the two
bands the field actually queries — not a marginal gain. That does not make it
automatically correct (it is a format change, so it needs dual-read, an upgrade
path, and a MINOR release under our format-preservation rule), but it is now the
best-sized remaining performance item and it should be evaluated on those terms
rather than dismissed.

The prior estimate is not retracted for common-term ranked, where it was
accurate: there `load_page` is 28.3% and the same change buys much less.
