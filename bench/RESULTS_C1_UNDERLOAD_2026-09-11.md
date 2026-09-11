# C1: concurrent throughput — pg_fts scales (2026-09-11, v1.6.1)

> **SUPERSEDED for cross-engine claims (2026-09-11).** The like-for-like re-run is
> `bench/RESULTS_C1X_CROSSENGINE_2026-09-11.md`. Two corrections it makes to text below:
> (1) **vchord does NOT collapse** — re-measured with a peak sweep and `mpstat`, it peaks
> at 8 clients then declines only 4.7%/7.2% by 32, a saturation plateau on an 8-core host;
> (2) all four engines plateau at 8 clients for the same host-CPU reason, so no engine
> "falls over". pg_fts still has the best scaling factor (10.7x) and the worst absolute
> ranked throughput.



ROADMAP C1 asked the question the whole competitive story was missing: **does pg_fts
hold up under concurrency, or does throughput collapse?** Single-client medians —
everything we had published — cannot answer it, and one rival (vchord) demonstrably
collapses, so the risk was real.

**Answer: pg_fts scales. 1 → 32 clients gives 10.7× on rare-term ranked and 9.9× on
common-term ranked, with throughput still rising at 32 clients.** No cliff.

---

## Correction to my own audit

`bench/COVERAGE_AUDIT_2026-09-10.md` said pg_fts's under-load arm was "missing". That
was **wrong**: `bench/data_5way/ftsx_underload.txt` has had our numbers since Aug 27.
What is corrupt is `bench/data_soak_bench/bench_ftsx_sidecar.json` (truncated, no
`under_load` key) — a *different* file from a *different* run. The audit conflated them.

The Aug-27 pg_fts data was real and already answered the scaling question:

| engine (Aug 27) | @1 | @8 | @16 | @32 | 1→32 |
|---|---|---|---|---|---|
| **pg_fts** (pre-1.5.0) | 396 tps | 3,127 | 3,898 | 3,965 | **10.0×** |
| pg_textsearch | 1,216 | 8,457 | 8,211 | 8,462 | 7.0× |
| pg_search | 680 | 5,175 | 6,457 | 6,692 | 9.8× |
| vchord | 452 | 1,322 | 1,100 | 1,161 | **2.6× then collapses** |

So the honest position is: we had the answer and I had not read it. The re-measurement
below was still worth doing — that data predates 1.5.0, when single-client rare was
14.8 ms against today's 5.89 ms.

## The v1.6.1 measurement

EC2 r6id.4xlarge, PG 17.10, 2,188,038 docs, index 1,421 MB, `nsegments=1`,
`shared_buffers=16GB` (matching the Aug-27 config), prewarmed, `pgbench` 30 s per band
per client count. Harness: `bench/underload.sh`. Raw:
`bench/data_c1_2026-09-11/`.

| band | @1 | @8 | @16 | @32 | 1→32 |
|---|---|---|---|---|---|
| rare k10 (ranked) | 99 tps / 10.1 ms | 767 / 10.4 | 1,056 / 15.1 | **1,060 / 30.2** | **10.7×** |
| common k10 (ranked) | 21 tps / 47.8 ms | 165 / 48.3 | 205 / 78.0 | **208 / 154.0** | **9.9×** |
| count(\*) common | 454 tps / 2.2 ms | 3,566 / 2.2 | 2,930 / 5.5 | 2,922 / 11.0 | 6.4× |

Shape of interest: for both ranked bands, latency is **flat from 1 to 8 clients**
(10.1 → 10.4 ms; 47.8 → 48.3 ms) while throughput rises ~7.7×, i.e. we are genuinely
idle-parallel up to 8 concurrent queries on 16 vCPUs. Beyond that latency grows roughly
linearly with client count while tps plateaus — the expected saturation curve, not a
regression. `count_common` peaks at 8 clients and holds ~2,900 tps.

## Why these numbers are NOT comparable to the Aug-27 table

I have to flag this rather than let the tables sit side by side:

- My bands use `WHERE d @@@ q ORDER BY d <=> q LIMIT 10` — a boolean match **plus** a
  ranked sort.
- The Aug-27 harness clearly used something cheaper. Its rivals' under-load @1
  latencies (0.82 / 1.47 / 2.22 ms) are **3–4× faster than the same run's own
  single-client medians** (2.96 / 4.58 / 7.29 ms), which is only possible with a
  different, lighter query.
- The original harness is gone (it was in `/tmp`), so the exact form is unrecoverable.

**Harness validation** (the reason I trust the new numbers): `count_common` measures
**2.204 ms @1 client** against the single-client benchmark's **2.20 ms** — an exact
match on an independent path. The ranked bands read ~1.7×/1.3× higher than
`fts_search()` because they do strictly more work (`@@@` + `ORDER BY` vs the index-only
top-k SRF). Both are legitimate; only one is comparable to a given prior number.

**Consequence:** the cross-engine table above is Aug-27 data on all four engines and is
internally consistent; the v1.6.1 table is pg_fts only. A like-for-like
cross-engine re-run on current versions needs all four re-measured with one documented
query form. That is now the open part of C1.

## What this changes

- **The scaling risk is closed.** pg_fts does not have vchord's collapse; its shape
  matches pg_search's, the best-scaling rival.
- **It reframes ROADMAP 4a.** I had called common-term ranked (36.16 ms vs pg_search's
  2.12) the top performance item. Under concurrency the gap is a *throughput* gap
  (208 vs ~6,300 tps at 32 clients) with the same root cause and no additional
  mystery — so 4a's priority is unchanged, but the argument for paying a format-change
  cost to fix it is now stronger, because it caps concurrent capacity too.
- **`count(*)` remains our standout**: 2,922 tps at 32 clients on a 735k-match term,
  against pg_search's 54 tps in the Aug-27 run (its `count_common` was 152–589 ms).
  That is a ~50× advantage on a real workload, and two rivals cannot do it at all.

## Also fixed here

`bench/underload.sh` is new and is the harness this should have had. It builds the whole
JSON in memory, writes it with a single redirect, and then **verifies it parses** before
reporting success — specifically so the failure that lost the earlier pg_fts arm (a
truncated 940-byte file with no closing brace) cannot recur silently. It also skips a
band with a clear message if the query does not execute, rather than recording zeros.

## Open

- Cross-engine re-run on current versions with one documented query form (the remaining
  half of C1).
- C2 (ingest/update throughput) and C3 (NDCG vs rivals) are untouched.
