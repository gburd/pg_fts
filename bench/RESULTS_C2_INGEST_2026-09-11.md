# C2: ingest throughput and the pending-list curve (2026-09-11, v1.6.1)

ROADMAP C2 asked for what bulk-build timing cannot show: **sustained INSERT rate into a
live index, and how ranked query latency degrades as the pending list grows between
merges** — the behaviour a production user actually hits. Previously unmeasured for
every engine.

This is the **pg_fts arm only**. Cross-engine comparison is not done (see Open).

## Rig

EC2 r6id.4xlarge, PG 17.10, pg_fts **1.6.1**, `shared_buffers=16GB`,
`maintenance_work_mem=1GB`, **`autovacuum=off`** so the measured maintenance is the only
maintenance. Base corpus: **1,000,000** Wikipedia documents, indexed, merged and
vacuumed to a settled 792 MB / `nsegments=1` — i.e. ingesting *into* a quiet index, not
during a build.

Then 8 batches × 25,000 rows (200k total), timing each batch and taking a median-of-5
ranked query latency after each. Inserted rows reuse existing `content` **and its
pre-computed `ftsdoc`**, so this measures index maintenance rather than `to_ftsdoc()`
analysis cost.

## Result: ingest decays 41%, query latency grows 16%, and merge restores both

| batch | rows/s | ranked latency after |
|---|---|---|
| 1 | **370.7** | 7.6 ms |
| 2 | 290.5 | 7.9 |
| 3 | 276.7 | 8.1 |
| 4 | 263.4 | 8.5 |
| 5 | 250.1 | 8.7 |
| 6 | 234.6 | 8.7 |
| 7 | **208.2** | 8.7 |
| 8 | 217.0 | **8.8** |
| *after `fts_merge`* | — | **7.8** |

**Ingest rate falls 41%** (371 → 217 rows/s) across only 200k rows, and **query latency
rises 16%** (7.6 → 8.8 ms) then **plateaus** from batch 5 onward. `fts_merge` restores
latency to 7.8 ms — essentially the pristine 7.6 — confirming the degradation is
entirely pending-list occupancy, not permanent index damage.

The latency plateau is the more reassuring half: the pending list costs a bounded ~16%,
it does not grow without limit. The ingest decay is the real cost, and it is steady
rather than cliff-shaped.

## Maintenance costs on the grown index

| operation | cost |
|---|---|
| `fts_merge` absorbing 200k pending rows into 1M docs | **292.6 s** |
| `DELETE` 300,852 rows then `VACUUM` | **242 s**, rc=0 |
| index after merge, before `fts_vacuum` | **36 GB** |
| index after `fts_vacuum` | **756 MB** |

**The 36 GB → 756 MB transient is a 49× amplification**, and it is the extend-only
merge residue documented in `bench/DIAG_WORKER_FRAGMENTATION.md` — now quantified at a
much more alarming ratio than the 3.2× seen after a plain build. It is fully reclaimable
and not a leak (extend-only allocation is a deliberate safety property: it prevents a
committed merge's freed pages being recycled while in-flight reads still point through
them). But an operator watching disk during a merge on a 1M-doc index would see it grow
to 36 GB, and nothing in our documentation warns them.

**That is the actionable finding from C2.** Peak transient disk during merge is not
proportional to index size in any way a user could predict, and it needs documenting —
along with the fact that `fts_vacuum` is what returns it.

Also worth noting: the `VACUUM` after deleting 300k rows completed in **242 s**. On
1.6.0 and earlier this is the workload that never terminated (see
`bench/P0_VACUUM_HANG_2026-09-10.md`), so C2 doubles as an independent confirmation that
the P0 fix holds at a different scale and corpus size.

## Harness defects found (both would have produced fake results)

Recorded because the first run produced numbers that were physically impossible, and
noticing that is the only reason this note has real data:

1. **`psql -v` does not expand a bare `:var` inside `-c`.** The first run's `INSERT`
   was therefore syntactically invalid every batch, inserted **nothing**, and the
   harness reported **6.5 million rows/s** — it was timing a no-op. Fixed with textual
   substitution *plus* a row-count assertion that aborts the run if a batch does not
   insert exactly `BATCH` rows, so a silent no-op is now unrepresentable.
2. **Wrapping `psql` in `/usr/bin/time` folded ~10 ms of process startup into every
   latency sample**, which is why the first run reported a suspiciously flat "10.0 ms"
   for all eight batches regardless of index state. Now measured server-side via
   `\timing` in a single session, median of 5.

A third, smaller one: the initial `INSERT ... LATERAL (SELECT ... WHERE id = ...)` form
matched nothing because the id space is sparse after deletes (39..13,922,213 for 749k
rows). Replaced with a validated self-select using `row_number()`, checked on 100 rows
before committing to a long run.

## Open

- **Cross-engine comparison.** Only pg_fts is measured. The other three engines' ingest
  paths differ fundamentally (pg_search and vchord maintain their own segment
  structures; pg_textsearch has no pending list), so a fair comparison needs per-engine
  query forms decided as carefully as C1's — that is a separate run.
- **Longer ingest run.** 200k rows into 1M shows the trend clearly but does not find
  where the ingest decay levels off, or whether the latency plateau holds at 10× the
  pending volume.
- **The 49× transient** should be reproduced at a second scale before being written into
  user-facing docs as a general rule.

## Data

`bench/data_c2_2026-09-11/pg_fts.json` and `c2_run.log`. Harness `bench/ingest.sh`.

---

# CORRECTION (2026-09-11, same day): the 49x transient is INSERTs, not the merge

I flagged the 49× figure above as needing a second scale before going into user docs —
then put it in README and the SGML reference anyway, attributed to `fts_merge`. Both the
attribution and the framing were wrong. Verified at two scales
(`bench/data_m3_2026-09-11/two_scale_merge.log`):

| scale | settled | **after INSERTs, before any merge** | after merge | after `fts_vacuum` |
|---|---|---|---|---|
| 250k docs + 50k inserts | 272 MB | **7,716 MB (28.4×)** | 8,431 MB | 319 MB |
| 1M docs + 200k inserts | 792 MB | **32,378 MB (40.9×)** | 34,621 MB | 971 MB |

**The file is already 32 GB before `fts_merge` runs.** Merge adds only 715 MB (small) and
2,243 MB (large) — about 7%. So the transient is caused by **incremental INSERTs**, and
attributing it to the merge would send an operator to instrument the wrong operation.

## Mechanism, confirmed in the code and the data

`bm25_insert` stores a pending document **verbatim**, and if it does not fit a page
(`need > BLCKSZ - headers`) it takes `bm25_insert_oversized_as_segment` — indexing it
immediately as **its own one-document segment** (`pg_fts_am.c:5347-5352`).

On this corpus the average `ftsdoc` is **8,861 bytes** against an 8,192-byte page, and
**32.7% of documents exceed the threshold**. So a third of every insert batch becomes a
one-doc segment. That also explains `nsegments` going 1 → 8 during ingest, which I had
noted without explaining.

Verbatim storage alone accounts for only ~1.8 GB of the 30.8 GB growth; the one-doc
segment path accounts for the remaining ~19×.

**This is corpus-dependent, not a general property.** It scales with the fraction of
documents larger than a page — a corpus of short documents will not show it at all. The
user-facing docs now say that explicitly rather than stating a bare 49× as if it were
universal.

## Also disproven here: the ROADMAP 3b multi-pass hypothesis

3b proposed that a merge does `O(nsegments/FANOUT)` extend-only passes, based on
production logs showing `merging 8 of 128` → `8 of 121` → … That is not what happens on
these runs: **`passes=2`** at both scales, each logging `merging 1 of 1 segments`.

So the "~18 sequential passes" reading applied to a specific state (a 128-segment index
from a parallel build), not to merges generally. 3b's premise needs re-scoping to that
state before any code is written — and since parallel merge is already documented as a
regression not to use, its practical value drops further.

## What I should have done

Held the 49× out of user docs until it was reproduced, exactly as my own caveat said. The
correction cost one extra EC2 run; publishing it unverified would have cost an operator
chasing merge disk usage that merges do not cause.
