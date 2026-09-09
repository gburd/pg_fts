# Diagnosis: "per-worker output fragmentation" (ROADMAP 3a) — 2026-09-09

**Verdict: the hypothesis is disproven and the claim that motivated this item is
withdrawn.** A parallel build does not produce a larger index. It produces more
*reclaimable residue*, which `fts_vacuum` removes completely.

Two independent arms reached this conclusion: an empirical arm on EC2 and a
code-reading arm (`bench/REVIEW_WORKER_FRAGMENTATION.md`). This document records the
measurements; the review records the code argument.

---

## The measurement that settles it

`maintenance_work_mem = 1GB`, 2,188,038 documents, index on a stored `ftsdoc`
column. **Empirical arm:**

| | build | size after build | live pages | freed pages | avg fill of live pages | `fts_vacuum` | **size after vacuum** |
|---|---|---|---|---|---|---|---|
| serial | 492.5 s | 4,406 MB (564,013 pg) | 173,529 | 390,483 (69.2%) | **98.76%** | 360.3 s | **1,355 MB (173,530 pg)** |
| 4 workers | 505.4 s | 5,139 MB (657,853 pg) | 173,529 | 484,323 (73.6%) | **98.76%** | 422.1 s | **1,355 MB (173,530 pg)** |

Not merely equal in size — **identical in every structural field**: 173,529 live
pages, 1,398,411,640 live bytes, average fill 8,058.7 / 8,160 B, the same per-flag
breakdown (POSTING 141,814 pg @ 98.53%, DICT 30,992 @ 99.82%, DOCLEN 631 @ 97.91%,
DICTINDEX 92 @ 98.82%), the same `nterms` 7,357,921, the same single segment.

**The parallel and serial builds produce the same logical index.** Only the volume
of freed-but-unreclaimed pages differs (484,323 vs 390,483).

Correctness identical at every configuration: `year` 734,896 / `slovakia` 10,875 /
`hungary` 24,097.

### Independent confirmation (lead)

Run separately, in an isolated database, at the same `maintenance_work_mem=1GB`
(`bench/data_gating_2026-09-09/vacuum_comparison.log`):

| workers | pre-vacuum | post-vacuum | segments | `year` |
|---|---|---|---|---|
| 0 | 4,605 MB | **1,420 MB** | 1 | 734,896 |
| 4 | 5,365 MB | **1,420 MB** | 1 | 734,896 |

Same conclusion — serial and parallel converge to the same size — reached
independently.

### An unresolved discrepancy, stated rather than smoothed over

The two arms agree that serial == parallel, but disagree on the **absolute floor**:
1,355 MB (173,530 pages) versus 1,420 MB (~181,760 pages). Mine is ~8,230 pages
(~64 MiB, 4.7%) larger.

Note that the empirical arm's post-vacuum page count is exactly its live-page count
plus one (173,529 + metapage), i.e. **its vacuum reached the exact live floor**,
while mine settled above it. The likely explanation is that a single `fts_vacuum`
call does not always converge to the floor — plausibly depending on where live data
sits relative to the truncation point, since truncation can only reclaim a
contiguous tail (below). **This is unverified.** The arm was cut off before it could
answer, and the host is terminated.

It does not affect the verdict, because each arm compared serial against parallel
*within its own setup*.

**RESOLVED while writing this up.** `doc/pg_fts.sgml:712` already documented the
correct behaviour: "A single `fts_vacuum()` call reclaims most of the space; a second
converges to the floor." My 4.7% residual is exactly that. The empirical arm's run
reached the floor because it vacuumed more than once (or hit the favourable case).
The bug was in `README.md`, which claimed convergence "in one call" and contradicted
the reference documentation — now corrected to match, citing this measurement.

---

## Why the hypothesis was wrong

The working hypothesis I gave the team was: *each participant packs its own pages,
so every per-participant flush leaves a partially-filled last page, and more
participants means more partial pages.*

**Disproven two ways.**

1. **Empirically.** Live pages measure **98.76% full**, and 173,521 of 173,529 are
   above 90%. There is no meaningful partial-page population to blame.
2. **Arithmetically** (from the code review). A segment writes at most four page
   chains, and each writer advances only when the next item does not fit
   (`pg_fts_am.c:1757-1760, 2617-2619, 1867-1869`) — never early, never on a term or
   flush boundary. All terms in a segment share **one** posting chain
   (`:1559-1564`). So per-segment partial-page slack is ~4 pages, and even at the
   128-segment cap the total possible slack is **~4 MB** against measured deltas of
   781–1,623 MB. Off by 200–400×.

---

## What the residue actually is, and why it is not a bug

Merge and build output is allocated **extend-only**, deliberately
(`pg_fts_am.c:4665-4672`). The comment is explicit about why: a committed merge
frees its input pages to the FSM, and without extend-only the *next* merge's
allocation would recycle those freed blocks as output while in-flight read chains
still thread through them — "giving a wrong read or a SIGBUS". So growing the file
rather than reusing freed space is a **correctness guarantee**, not sloppiness.

`bm25_truncate_free_tail` (`:4437`) then reclaims only a **contiguous free tail**:
its loop walks down from EOF and `break`s at the first live block (`:4446-4449`).
Because the final merge output sits at the top of the file, the freed pages beneath
it are unreachable by truncation. They wait for `fts_vacuum`'s compaction pass,
which relocates live pages toward the front and *then* truncates.

That is the whole phenomenon: **pre-vacuum `pg_relation_size` is not a measure of
index size.** It is live data plus intentional, reclaimable residue.

---

## Consequences

- **ROADMAP 3a: closed.** Nothing to fix. The bytes are intentional and fully
  reclaimable.
- **The published claim is withdrawn** from `README.md`, `doc/pg_fts.sgml`,
  `doc/COMPARISON_MATRIX.md` and `bench/BENCHMARK_SUMMARY.md`, each stating the
  withdrawal explicitly rather than silently swapping the number. The item-3 sweep
  that produced "4,605 vs 5,386 MB" did not vacuum, so it was measuring reclaimable
  garbage — confirmed by both arms.
- **The 1,421 MB headline benchmark index size is unaffected**, because that build
  did run `fts_vacuum`. Both arms confirm it is the same *kind* of number
  (post-vacuum).
- **Operational rule now documented:** run `fts_vacuum` once after a large build,
  and do not judge index size before you do.
- **ROADMAP 3b opened** for the one real defect found on the way: at
  `pg_fts_am.c:4191` the parallel merge pass falls **through** to the serial collapse
  loop with no early return, so a parallel `fts_merge` does the work twice — a
  sufficient explanation for the measured 1.45× slowdown by itself.

## Follow-ups

1. **ROADMAP 3b** — the double-pass merge (`pg_fts_am.c:4191` falls through).
2. Whether the residue volume is worth reducing at all, given it is a safety
   property and vacuum reclaims it fully. Probably not, but the extend-only window
   could in principle be narrowed to per-merge rather than per-loop.

## Provenance and limitations

The empirical arm was a sub-agent that **hit its execution limit before writing its
deliverable**; its numbers are reproduced here verbatim from its final progress
report, and the independent confirmation is my own run
(`bench/data_gating_2026-09-09/vacuum_comparison.log`). The 256MB and 2GB
vacuum-inclusive sweeps it planned were **not completed**, so the trend across
`maintenance_work_mem` is unmeasured — only the 1GB pair is. The EC2 host has been
terminated.
