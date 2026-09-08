# Sparsemap batched-filter quantification (2026-09-08) — ROADMAP item 9, PARTIAL

ROADMAP item 9's TODO was: "quantify the merge-path `sm_contains_many` benefit
under a delete-heavy workload." **Partially answered, and the answer so far is
"no measurable difference."** The delete-heavy half is NOT measured — see
Limitations, which are substantial and are the main reason this note exists.

## Rig

EC2 r6id.4xlarge, PostgreSQL 17.10, pg_fts 1.5.10, 2,188,038 Wikipedia articles,
`maintenance_work_mem = 64MB` (to force 5 segments), `shared_buffers = 64GB`.

Three separately compiled `.so` arms, each verified by md5 at load time so a run
provably used the binary it claims:

| arm | md5 prefix | tombstone membership path |
|---|---|---|
| `stock` | `282130b93169` | as shipped |
| `many` | `12c9359d8d3b` | batched `sm_contains_many` |
| `cursor` | `90b4ccf7dabc` | forward-resume `sm_contains` + `sm_cursor_t` |

## Result at zero tombstones: the three arms are indistinguishable

5 segments → 1, no deletes:

| arm | merge time | resulting index | correctness |
|---|---|---|---|
| stock | 231.6 s | 4,507,394,048 B | year 734,896 = truth ✓ |
| many | 233.7 s | 4,507,394,048 B | year 734,896 = truth ✓ |
| cursor | 233.2 s | 4,507,394,048 B | year 734,896 = truth ✓ |

Spread is **0.9%** (231.6–233.7 s) across arms, and the output index is
**byte-identical** in all three. At zero tombstone density that is the expected
result — there is nothing for a tombstone filter to do — so this establishes the
baseline and confirms the arms are otherwise equivalent, nothing more.

## Limitations — why the delete-heavy half is not reported

Being explicit, because the missing half is the part the ROADMAP actually asked
for:

1. **The `PGFTS_BENCH_NO_CLEANUP_MERGE=1` control does not exist.** The rig
   exports it to stop autovacuum cleanup from compacting the index before the
   timed `fts_merge`, having correctly observed that cleanup otherwise "collapsed
   5 segments -> 1, leaving fts_merge a 0.490 ms no-op". But `grep` over the
   pg_fts sources finds **no such environment variable** — it is a no-op. So even
   the zero-density numbers above may have been racing autovacuum compaction,
   and any delete-heavy run is worse: the merge being timed may be measuring
   whatever cleanup left behind.
2. **Every delete-heavy cycle recorded `tombstones_in_index=0`** with empty
   `deleted_rows` and `merge_ms`, i.e. the delete/vacuum stage never produced
   tombstones in the runs that completed. Those rows are unusable, not merely
   noisy.
3. **The rig double-launches each cycle.** Two `sm_cycle.sh` processes with the
   same tag appear repeatedly (the logging pipeline forks a subshell copy), and
   each stops the cluster the other is using — which produced cascades of
   `FATAL: the database system is shutting down` and eventually a postmaster stuck
   in a shutdown state that needed `-m immediate` plus crash recovery to clear.
4. Output is buffered through a `grep` pipeline, so a cycle's results appear only
   when it exits — a 25+ minute blind window that makes iterating expensive.

Attempted repairs: added `-w -t 300` to both `pg_ctl` calls (they lacked it), a
`flock` to serialize cycles, and full cluster recovery. Cycles then ran correctly
in the foreground (verified: an active `fts_merge` 26 minutes in), but the
double-launch remained, and the cost of continuing exceeded the value of the
answer.

## What this means for item 9

- **The batched filter is not a regression** — three arms within 0.9% and
  byte-identical output at zero density.
- **Its benefit under delete pressure remains unmeasured.** The honest position is
  unchanged from before this run.
- Worth noting the ranked-scan side of item 9 *was* already settled and shipped
  (the 8-way MRU cache degenerated to an O(chunks) head-walk on ascending scans;
  the resume cursor fixed it, measured 24 s → 2.5 ms at 2M docs / ~4M tombstones
  in 1.4.1). Only the merge path was open, and it stays open.

**Recommendation: leave item 9 open, and if it is picked up again, build the rig
fresh rather than repairing this one.** The specific requirements a redo needs:
a real way to suppress cleanup compaction (a GUC we actually implement, or
`autovacuum = off` on the table plus no manual `fts_vacuum`), a verified non-zero
tombstone count *before* the timed merge, one cycle per invocation with no
pipeline forking, and unbuffered incremental output.

## Provenance

`bench/data_sparsemap_2026-09-08/sm_sweep.log`. Collected off the host after the
measuring sub-agent was stopped with no output; the table above is read from its
raw log, not from a summary. The three-arm design is the agent's and is a better
experiment than the one I specified — it isolates the membership path rather than
inferring it from a profile.
