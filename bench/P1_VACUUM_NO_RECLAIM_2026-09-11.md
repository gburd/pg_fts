# P1: `VACUUM` does not reclaim pg_fts index bloat — and grows it (2026-09-11)

**Question asked:** must a user schedule `fts_vacuum` manually, or does the index keep
itself in check like autovacuum does for tables?

**Answer: manual `fts_vacuum` is currently required.** Worse, the automatic path does not
merely fail to reclaim — **each `VACUUM` pass grows the index by ~690 MB and reclaims
nothing.** Only an explicit `fts_vacuum` returns the space.

This is a **P1 usability/operability defect**, distinct from the 1.6.1 P0 (which was
non-termination). It is measured and reproducible, and the fix is not yet written.

Rig: EC2 r6id.4xlarge, PG 17.10, pg_fts 1.6.1, 200,000-document corpus,
`autovacuum = on`, `autovacuum_naptime = 10s`, `log_autovacuum_min_duration = 0`.
Raw logs in `bench/data_autovac_2026-09-11/`.

## The headline measurement

Settled index 304 MB, then 45,000 inserts, then three consecutive `VACUUM docs`:

| step | index size | segments |
|---|---|---|
| settled (after `fts_vacuum`) | **304 MB** | 1 |
| + 45,000 inserts | 7,021 MB | 8 |
| after `VACUUM` #1 | **7,734 MB** (+713) | 1 |
| after `VACUUM` #2 | **8,423 MB** (+689) | 1 |
| after `VACUUM` #3 | **9,111 MB** (+688) | 1 |
| after explicit `fts_vacuum` | **344 MB** | 1 |

`VACUUM` correctly merges (8 → 1 segments) but writes its output **extend-only** and then
does not truncate, so every pass adds another copy: ~690 MB each time, monotonically. A
scheduled hourly `VACUUM` on an insert-heavy table would grow this index indefinitely.

`fts_vacuum` reclaims it completely in one call (9,111 → 344 MB, **26×**).

## What does work, and the false lead I chased

Automatic reclaim is **not** entirely dead — it fires when a table has dead tuples:

| scenario | before | after autovacuum |
|---|---|---|
| INSERT + UPDATE (creates dead tuples) | 8,732 MB | **610 MB** ✓ |
| INSERT-only, 40k rows | 6,123 MB | 6,123 MB — never reclaimed |
| INSERT-only, 45k rows | 6,830 MB | 7,392 MB — grew |

I first thought the trigger was the whole story: PostgreSQL's autovacuum fires on **table
dead tuples**, and pure inserts create none. That is real but not sufficient —
`autovacuum_vacuum_insert_threshold` (1,000 + 0.2 × 200,000 = 41,000) means 40k inserts
sat just under the threshold and 45k crossed it. So insert-only *does* eventually
schedule a vacuum.

The problem is what that vacuum then does: it merges and grows. The 45k run shows
`autovacuum_count` going 1 → 2 with the index still at 7,392 MB after four minutes.

I also chased a "needs two cycles" theory (first pass merges, second reclaims). **Ruled
out by the three-pass table above** — the third pass is as unhelpful as the first.

## Where the fix belongs

`bm25_vacuumcleanup` (`pg_fts_am.c:6053-6065`) gates reclaim on ≥25% of blocks being
free:

```c
if (nblocks > 16 && freeblks > nblocks / 4)
    (void) bm25_vacuum_compact(info->index);
```

and `bm25_vacuum_compact` (`:4646`) then short-circuits when
`bm25_index_is_compacted()` is true, doing only a tail truncate. After a merge the index
*is* one segment (`nlive == 1`), and the freed pages sit **below** the new output, so
there is no contiguous free tail to truncate — the pass does nothing while having just
written a fresh copy.

**MEASURED (2026-09-11) — the gate and predicate are both CORRECT.** I instrumented a
real cleanup pass rather than reasoning further:

```
PGFTSDIAG gate: nblocks=912246 freeblks=853384 (93.5%) gate_pass=1 is_compacted=0
```

The gate passes, `is_compacted` correctly says *not* compacted, and
`bm25_vacuum_compact` **is** therefore called — and the file still grew 7,100 → 7,888 MB
in that same pass. So the defect is inside `bm25_vacuum_compact`, not in the decision to
call it. That rules out the entire gate/predicate theory above.

**Root cause, from the server log:**

```
ERROR:  canceling autovacuum task
```

Autovacuum's cleanup is being **cancelled part-way through compaction**. It holds
`bm25_maintenance_lock` for flush → merge → compact, and autovacuum yields to any
conflicting lock request. So the sequence is: merge writes a fresh extend-only copy
(+~690 MB), then the vacate/pack/truncate work is killed before it can reclaim — leaving
the index strictly larger than before. Repeating the cycle repeats the growth, which is
exactly the monotonic +690 MB per pass in the table above.

`bm25_vacuum_compact`'s own backstop ("never return larger than we started",
`pg_fts_am.c:4681-4700`) cannot help, because the cancellation unwinds before it runs.

This also explains why the INSERT+UPDATE scenario reclaimed successfully: that pass
happened to complete without being cancelled.

Do not "fix" this by removing the gate. The gate exists for a good reason — the comment
notes an unconditional rewrite is "the dominant cost on a large index (each rewrite
streams the whole multi-GB segment through the buffer pool twice)". A correct fix has to
distinguish *"already at the floor"* from *"one segment but sitting on top of a mountain
of freed pages"*, which is precisely what `bm25_index_is_compacted` was written to do.

## Recommendation

1. **Document immediately** that `fts_vacuum` must be scheduled for insert-heavy
   workloads, and that plain `VACUUM` does not substitute. True today, and the
   user-visible answer to the question.
2. **Make the merge not leave the index bigger than it found it.** The cleanest fix is
   for the merge step to truncate its own free tail when it finishes single-segment —
   cheap, no full vacate+pack, and it removes the +690 MB at source so a cancellation
   can no longer leave net growth. This is the fix I would write.
3. **Make compaction interruption-safe/resumable**, or split it so the *reclaim* half is
   not inside the cancellable region. Today a cancelled pass is strictly worse than no
   pass at all, which is the property that turns a missed optimisation into unbounded
   growth.
4. Consider whether autovacuum should attempt pg_fts compaction at all, versus a
   dedicated background worker that will not be cancelled by ordinary lock conflicts.

Until 2 lands, the honest guidance is: **schedule `fts_vacuum`**, and do not rely on
autovacuum to keep a pg_fts index in check.
