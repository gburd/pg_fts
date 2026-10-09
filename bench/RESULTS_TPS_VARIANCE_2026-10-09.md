# Why 1.11.0's throughput was up to 13% below the 39b6a42 run (2026-10-09)

Plan: `bench/PLAN_TPS_VARIANCE_2026-10-09.md` (c65fdad, written before the run; the
addendum was written after the six-host run and before the shared/private A/B).  Data:
`bench/data_tpsvar_2026-10-09/` (`tvN/` per host, microbenchmark sources and scripts at
the top level).  Six fresh r7gd.4xlarge, same AMI, subnet, AZ (us-east-2b), PG 17.10
build, settings, corpus and index (1,489,600,512 bytes on every host) as both earlier runs,
the 1.11.0 release from its PGXN zip.

## Answer

**Not the release, and not something pg_fts can measure itself out of: the host.**  The
same binary on the same index runs rare k10 at 16 clients at **~27,000 tps on some hosts
and ~20,000 on others**, and a host can switch between the two levels while it runs.  The
2026-10-07 run happened to land on a fast host and the 2026-10-09 run on a slow one (the
39b6a42 control in that run was 0.5-13.5% below its own earlier numbers, by the same
amount as the release).  The 1.11.0 release vs 39b6a42 comparison inside each run, which
is what the release claims rest on, is unaffected.

What pg_fts CAN change is how much a slow host costs it: the loss sits in shared-memory
cache-line traffic (buffer pins and buffer content locks, and the shared doclen copy), so
a query that touches fewer shared cache lines loses less.  That is a code change with a
measurable target (below), not a fix for the variance itself.

## Measured

### The spread is per host and per moment, not per binary

Rare k10 c16 tps, same binary (1.11.0 release), same index, 30 s each:

| host | unsettled (after build) | settled r1 | settled r2 | later default runs (hp / fix / sd) |
|---|---|---|---|---|
| tv5 | 26,868 | 26,961 | 26,931 | 26,644-26,825 / 26,776-26,825 / 26,805-26,848 |
| tv2 | 20,565 | 20,465 | 20,321 | 20,761-20,762 / 20,711-21,020 / 20,199-20,344 |
| tv3 | 19,909 | 19,750 | 19,824 | 18,912-19,519 / 16,888-19,611 / 18,496-18,884 |
| tv6 | 20,183 | 20,156 | 20,057 | 19,824-20,164 / 20,045-20,283 / 19,741-19,961 |
| tv1 | 26,169 | **26,357** | **18,281** | 19,127-19,907 / 19,477-19,801 / 25,907-26,205 |
| tv4 | 26,657 | **26,762** | **16,634** | 18,426-18,909 / 18,190-18,419 / 26,692-26,749 |

tv1 and tv4 dropped from the fast level to the slow one between two settled runs 14 minutes
apart (12:40 and 12:54 UTC) and were back at the fast level in the last run (15:16).  A one-hour gap between two settled runs on ONE host
moved throughput more than the release vs 39b6a42 difference ever did.  The 2026-10-07 host
showed the same thing within its own session (20,133-20,469 early, 26,085-26,260 later,
`data_A_2026-10-07/run/fts/tps_probes.txt`, recorded then as "unexplained").

Single-client cost is the same on every host: c1 tps 1,865-1,971 (rare), 1,476-1,548
(common); per-query work in pg_fts (dictionary seek 216-220 us, scoring 57-60 us of core
time per rare transaction) is identical within 2% across a fast and two slow hosts.
`count(*)` -- which touches 6 buffers and no shared doclen copy -- runs at 70-76k tps on
every host in every state.

### What tracks it: memory access with 4 KiB pages

Single-thread pointer chase, idle host (`mbench.c`, `mbench2.c`):

| host | state at that time | 1 GiB, 4 KiB pages | 4 GiB, 4 KiB | 4 GiB, THP | c2c median | 16-thread contended atomic |
|---|---|---|---|---|---|---|
| tv5 | fast | **148.6 ns** | **161.9** | 118.5 | 263 ns | 144.9 ns |
| tv4 | (fast then slow) | 201.5 / 142.0 | 243.2 | 124.0 | 285 | 130.7 |
| tv1 | (fast then slow) | 190.7 / 149.4 | 242.1 | 122.6 | 275 | 134.3 |
| tv2 | slow | 178.3 | 235.8 | 121.1 | 233 | 144.1 |
| tv3 | slow | 194.5 | 240.5 | 122.3 | 200 | 124.2 |
| tv6 | slow | 181.3 | 229.3 | 117.3 | 223 | 145.4 |

(tv1/tv4: the first figure is from the second microbenchmark run, while they were slow; the
second from the first run, while they were fast.)  With 2 MiB pages every host is within
6%; with 4 KiB pages a host in the slow state takes 1.19-1.42x as long per load at 1 GiB
and 1.42-1.50x at 4 GiB as tv5.  The difference is in the
page walk -- under a hypervisor, a TLB miss on a 4 KiB page walks two page-table levels
(guest and host), and a host-side mapping that is not backed by large pages makes that walk
longer -- not in DRAM, cache-to-cache transfer or atomic throughput, which do not separate
the hosts (c2c is if anything faster on the slow ones).  The guest cannot see or change the
host-side mapping; it can change with host memory management while the instance runs,
which fits tv1/tv4 switching state.  That reading is inferred from where the cost is and
is not separate from it: it is what the evidence fits, not something measured from inside
the guest.

### Where the extra time goes on a slow host

Per-transaction core time at c16 = (% of samples) x (busy cores) / tps (`perf record -a`,
`vmstat`), rare k10, tv5 vs tv2 / tv3:

| | tv5 (fast) | tv2 | tv3 |
|---|---|---|---|
| total us / transaction | 592 | 760 | 778 |
| buffer pin + content-lock atomics (PinBuffer, LWLockAcquire/Release, `__aarch64_cas4_acq_rel`, `__aarch64_ldadd4_sync`) | **73** | **176** | **172** |
| shared doclen lookup (`bm25_doclen_cursor_lookup`) | **60** | **106** | **111** |
| dictionary seek (`bm25_dict_seek`, binary search in pages) | 216 | 218 | 220 |
| scoring / traversal | 60 | 57 | 57 |

Common k10: atomics 124 -> 261 / 288 us, the rest within 6%.  The callers of the atomics
are `ReadBuffer` / `UnlockReleaseBuffer` in `bm25_dict_seek` and `bestfirst_collect`: one
pin and one share lock per index page read, on pages every concurrent query reads (the
dictionary-index chain, the dictionary page and the posting pages of the same term).  IPC
fell from 1.88 (tv5) to 1.45 / 1.42 (tv2 / tv3) with backend stalls 48% -> 57%.

### Ruled out (measured, each alternating on all six hosts)

- **Huge pages for shared_buffers** (`huge_pages=on`, 17,000 x 2 MiB reserved, status
  confirmed `on`): rare c16 0.87-1.06x the same round's 4 KiB run (tv3 round 2: 17,042 vs
  19,519, the one outlier, inside tv3's own 16,888-19,611 default spread), never moving a
  slow host to the fast level.
- **The shared doclen copy on 2 MiB pages** (`/dev/shm` remounted `huge=always`,
  `ShmemPmdMapped` confirmed) and **inside the hugetlb main segment**
  (`min_dynamic_shared_memory=256MB`, the DSM shows 0 MB of 4 KiB RSS): 0.98-1.05x the
  default on five hosts (tv3: 0.91-1.12x, its own spread); no slow host reached the fast
  level.
- **THP** (`always` on every host), **NUMA** (one node), **pgbench threads** (`-j 16` vs
  `-j 8` within 1%), **settling** (unsettled = settled on the stable hosts), **checkpoint /
  writeback** (no dirty pages during runs), **compaction / migration** (0 in `/proc/vmstat`).

## The shared doclen copy: a trade, re-measured on six hosts

`pg_fts.shared_doclen` off vs on (default), alternating, 3 rounds, 20 s points
(`tvN/sd.log`):

| | rare c16 | rare c32 | rare c64 | mid c16 | mid c32 | mid c64 |
|---|---|---|---|---|---|---|
| fast hosts (tv1, tv4, tv5 in fast state): off / on | 1.01-1.02 | 0.95-0.97 | **0.83-0.84** | 1.01-1.02 | 0.95-0.97 | **0.85-0.86** |
| slow hosts (tv2, tv3, tv6): off / on | **1.08-1.21** | 1.06-1.09 | 0.87-0.98 | **1.10-1.22** | 0.99-1.10 | 0.90-0.92 |

The shared copy is what 1.10.0 added for I6 (private copies made throughput fall with
client count); that holds on every host at 64 clients (private is 2-17% worse).  At 16
clients on a slow host, private copies are 8-21% faster, because the shared copy's 5 MB
of DSM pages are then read by 16 cores through the slow walk.  1.10.0's I6 A/B was taken on
one host, at the fast level by its numbers.  Neither setting is better everywhere; the
default stays on (it bounds the 64-client case on every host, which is the case I6 was
about) and this trade goes into the documentation and the ROADMAP.

## Remediation

1. **Benchmark protocol (done in this file; applies from the next run).**  A between-run
   absolute tps comparison on EC2 is not meaningful at better than ~35% on this instance
   type: one host's state moves it from ~27k to ~17-20k.  Release claims are
   within-host A/Bs, as 1.11.0's were.  Every throughput run now also records the 1 GiB
   4 KiB-page pointer chase (`mbench2.c`) before and after, so a reader can see which state
   the host was in; the RESULTS_111 "0.5-13.5% lower, cause unmeasured" line is replaced by
   this explanation.
2. **pg_fts code (not done; ROADMAP item, needs its own A/B).**  Reduce shared cache-line
   traffic per query, which is the part of the slow-host loss pg_fts controls:
   - a rare k10 query reads 278 shared buffers, of which ~210 are three lookups of the same
     term (maxhits bound, global df, per-segment cursor), each walking the dictionary-index
     chain (up to 85 pages, ~22-30 on average) -- `fts_index_df` alone costs 32-102
     buffers per term depending on where it sorts.  Looking a term up once per scan and
     reusing it, and keeping the dictionary-index first-terms in the existing
     per-backend relcache chunk (`rd_amcache`) instead of re-reading the chain under
     buffer locks, would remove most of those pins and lock acquisitions.  On the slow
     host those cost ~176 us of a 760 us transaction; on the fast host 73 of 592.
   - That is an estimate of the ceiling, not a measurement of the change: by rule 1 no
     number is claimed until the change is built and A/B'd on fast and slow hosts.

## What this does not show

- Which physical property of the EC2 host flips the state.  Inferred from the evidence
  (4 KiB-page walks only, guest-invisible, changes while the instance runs); not
  observable from inside the guest.
- Other instance types or x86.
