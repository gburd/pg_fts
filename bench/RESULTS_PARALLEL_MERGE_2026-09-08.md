# Parallel merge at scale (2026-09-08) — ROADMAP item 1

Measured on EC2 r6id.4xlarge (16 vCPU, 128 GB, local NVMe), PostgreSQL 17.10,
pg_fts 1.5.10, 2,188,038 Wikipedia articles, `maintenance_work_mem = 64MB` to force
an 8-segment index, `shared_buffers = 64GB`.

ROADMAP item 1 asked only for the speedup number, since parallel merge was already
implemented and verified correct. **The answer is that it is slower.**

## Result: parallel merge is 44% SLOWER and produces a 19% LARGER index

Every run merged the same 8-segment, 7,185 MB index down to `nsegments = 1`.

| run | `max_parallel_maintenance_workers` | workers observed | merge time | resulting index |
|---|---|---|---|---|
| s1 | 0 (serial) | 0 | **230.8 s** | 8,606 MB |
| s2 | 0 (serial) | 0 | **230.3 s** | 8,606 MB |
| p1 | 8 | 0 (see below) | 229.5 s | 8,606 MB |
| p2 | 8 | 0 (see below) | 232.0 s | 8,606 MB |
| **g1** | **3** | **3** | **333.6 s** | **10,229 MB** |
| **g2** | **3** | **3** | **330.7 s** | **10,229 MB** |
| **h1** | **1** | **1** | **333.5 s** | **10,158 MB** |

Serial median **230.6 s** vs parallel **333.5 s** → **1.45x slower**, and the index
comes out **1,623 MB (19%) larger**. One worker is as bad as three, so this is not
a scaling curve — it is a fixed penalty for taking the parallel path at all.

## The `mpmw=8` rows are serial runs in disguise

At `mpmw = 8` the sampler saw 0 workers and the timing matched serial exactly.
That looked like a measurement gap, so it was re-run with postmaster `DEBUG1`
(`confirm8.log`). Workers **do** get registered and started:

```
DEBUG: registering background worker "parallel worker for PID 120257"   (x8)
DEBUG: starting background worker process "parallel worker for PID 120257"
DEBUG: unregistering background worker "parallel worker for PID 120257"
DEBUG: background worker "parallel worker" (PID 120258) exited with exit code 0
```

They register, start, and **exit with code 0 within ~2 ms** — before doing any
work. The merge then completes serially in 231.4 s. So `mpmw = 8` silently falls
back to serial, which is why it looks fast: it *is* the serial path.

That means the honest comparison is s1/s2/p1/p2 (serial, ~230 s) against
g1/g2/h1 (genuinely parallel, ~332 s). Four runs of the fast path and three of
the slow one, all on identical input.

## Correctness is unaffected

Match counts were captured before and after every merge and are identical in all
seven runs: `year` 734,896 / `slovakia` 10,875 / `hungary` 24,097, and every run
converged `nsegments` 8 → 1. So the parallel path is *correct* — as the ROADMAP
said — just slower and less space-efficient.

## Why this is plausible

Two mechanisms, both unverified but consistent with the numbers:

1. **The larger output is the tell.** A serial merge writes one output stream and
   packs pages densely. Per-worker output streams pack independently, so the
   19% growth looks like per-worker page fragmentation that the serial path avoids
   — and the extra bytes are extra I/O, which would explain the slowdown rather
   than being merely a side effect.
2. **A merge is sequential-I/O bound, not CPU bound.** On this host the corpus is
   in `shared_buffers` and the merge is a streaming k-way union; adding workers
   adds coordination and write amplification without adding a bottleneck to
   parallelize. The fixed cost at W=1 supports this.

## Recommendation

**Do not enable parallel merge, and consider whether the code should stay.** As
measured it is a 1.45x regression plus 19% bloat for zero benefit. Options, in
order of preference:

1. Leave it disabled by default (current behaviour — `mpmw` must be raised
   deliberately) and **document that raising it makes merges slower**, which is
   the opposite of what an operator would assume.
2. Investigate the 19% growth. If per-worker fragmentation is the cause and it is
   fixable, the CPU argument might still lose but the space regression would go
   away.
3. Remove the parallel merge path. It carries concurrency risk (this line has
   already produced three concurrency-fix releases) for a measured negative.

The `mpmw = 8` immediate-exit behaviour should also be understood before any of
this: a configuration that silently disables the feature it is supposed to enable
is a trap either way, even though here it happens to select the faster path.

## Provenance

Raw logs: `bench/data_parallel_merge_2026-09-08/matrix.log` (7 runs) and
`confirm8.log` (the DEBUG1 worker-lifecycle confirmation). Collected directly from
the host after the measuring sub-agent was stopped mid-task; the numbers above are
from its logs, not its summary.
