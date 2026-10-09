# Plan: why 1.11.0 throughput was up to 13% lower than the 39b6a42 run (2026-10-09)

Written before the diagnostic run.

## What is known (no new measurement)

- Same binary (39b6a42, md5 `4486203a`), same instance type, AMI, settings, corpus and
  index size.  Settled rare k10 at 16 clients: 26,568-26,941 tps on the 2026-10-07 host,
  23,533-24,634 on the 2026-10-09 host; common 22,356-22,392 vs 18,636-19,175; mid
  35,259-35,362 vs 33,178-34,234; `count(*)` 75,228-75,665 vs 74,818-75,022.
- On the 2026-10-09 host the same binary is FASTER single-client on every band (rare 0.64
  -> 0.54 ms, common 0.81 -> 0.70).  So it is not per-query cost; it is how throughput
  scales from 1 to 16 clients.  16 vCPU / tps = core time per transaction rose from 0.60
  to 0.67 ms (rare) and from 0.72 to 0.85 ms (common), while `count(*)`'s stayed at
  0.21 ms.
- `count(*)` does not score, so it never takes the shared doclen copy (`shdl_get`: an
  EXCLUSIVE LWLock to find and reference the copy, and another to drop the reference, per
  cursor).  The ranked bands do.  `count(*)` did not move; the ranked bands did.
- The 2026-10-07 host itself moved: the same arm-a binary measured 20,133-20,469 rare c16
  in probes early in that session and 26,085-26,260 later (`data_A_2026-10-07/run/fts/
  tps_probes.txt`, "unexplained").  So "host state" moves this number by up to 23% on one
  host.
- The 2026-10-09 host was noisier: within-arm c16 spread 5.8% (rare) and 9% (common),
  against 1.4% and 0.2% on the 2026-10-07 host; and there c64 > c16, on the old host
  c64 < c16.

## Hypotheses

- **H1 host-to-host variation**: different physical machines of one instance type differ
  this much on a 16-core, coherence- and memory-heavy load.  Not fixable in pg_fts.
- **H2 host state**: something time-dependent on one host (background writeback,
  checkpoint, page tables, scheduler) moves throughput; the settled protocol does not
  remove it.  Fixable in the protocol if found.
- **H3 a pg_fts contention point whose cost depends on the host**: a shared cache line
  every ranked query writes (the `shdl` LWLock and slot, the metapage buffer header and
  content lock) costs more where cache-line transfers are slower.  Fixable in pg_fts.

## Measurements

Six fresh r7gd.4xlarge, same AMI, subnet and setup as both runs, launched together; the
1.11.0 release from its PGXN zip; corpus loaded, stored column filled, `docs_idx` built.
On each host:

1. Host characterisation (C microbenchmarks, idle host): DRAM pointer-chase latency
   (1 GiB, 4 KiB pages), the same with 16 threads at once, 16-thread read bandwidth,
   core-to-core cache-line round trip from core 0 to each other core.
2. Unsettled probe: rare c16 straight after the build, before any CHECKPOINT (H2).
3. Settled throughput exactly as `tps2.sh`, twice: rare, mid, common, count.
4. Single-client latency (8 x 3, as the protocol) and pgbench c1 tps.
5. At rare and common c16: vmstat (idle and context switches), `perf stat` hardware
   counters where the VM exposes them, wait-event sampling from `pg_stat_activity`, and a
   system-wide `perf record` at c16 and c1 for a per-transaction cost by symbol.
6. `pg_fts.shared_doclen` off vs on at rare and common c16, alternating (H3: off removes
   the shdl lock).
7. pgbench `-j 16` vs `-j 8` at rare c16 (client-thread scheduling).

## Decisions

- H1 holds if the six hosts' settled rare c16 spread covers both earlier hosts' levels
  (about 24k-27k); and it is explained if it correlates with a microbenchmark.
- H2 holds if the unsettled probe or a later repeat differs from settled on one host by
  more than that host's run-to-run spread.
- H3 holds if the per-transaction cost growth from c1 to c16 sits in pg_fts symbols or
  in LWLock/buffer-pin code reached from pg_fts, or if `shared_doclen = off` changes c16
  throughput by more than the run-to-run spread, or if a host's slowdown is concentrated
  there.
- Remediation follows the hypothesis that holds: code for H3, protocol for H1/H2 (report
  the measured host spread; A/B only within one host, as already done).

## Addendum (2026-10-09 14:10 UTC, after the six-host run, before the measurements below)

Six-host result (data in `bench/data_tpsvar_2026-10-09/`): same binary, index and settings,
rare k10 c16 settled 26,931-26,964 on tv5, 19,685-20,465 on tv2/tv3/tv6, and 26,357-26,762
then 16,627-18,309 on tv1/tv4 within one hour.  Slow/fast correlates with a 4 KiB-page
DRAM pointer chase (1 GiB: 142-149 ns fast, 178-201 ns slow; tv1/tv4 moved with it), not
with THP, hugetlb shared_buffers, /dev/shm huge pages, c2c latency or contended-atomic
cost.  On slow hosts the extra per-transaction core time is in buffer pin/lock atomics
(73 -> 172-176 us of 592 -> 760-778) and the shared doclen lookup (60 -> 106-111 us); the
pg_fts per-query work (dict seek, scoring) is identical across hosts.  `shared_doclen=off`
recovers 13-23% of rare c16 on slow hosts (20,330 -> 25,025 on tv2), nothing on tv5.

H3 refined.  Two pg_fts levers, each a measurable reduction of hot-line traffic:
- **H3a** a rare k10 query reads 278 shared buffers; ~200 are three dictionary lookups of
  the same term (maxhits bound, global df, cursor), each walking the dictionary-index
  chain.  Doing the lookup once per (term, segment) per scan removes ~2/3 of that.
- **H3b** the shared doclen copy (DSM, 4 KiB pages) costs more than a private copy on slow
  hosts and nothing on fast ones; 1.10.0's I6 measurement (private worse at 32-64
  clients) was on one host.  Decide `shared_doclen`'s default from all six hosts at
  c16/c32/c64, rare and mid.
Measured on the same six hosts, alternating, against the 1.11.0 release; a change ships
only if it is never slower on the fast host and results are identical.
