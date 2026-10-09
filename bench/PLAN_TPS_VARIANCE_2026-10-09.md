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
