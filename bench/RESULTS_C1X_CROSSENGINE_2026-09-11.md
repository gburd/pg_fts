# C1 cross-engine concurrent throughput (2026-09-11)

The like-for-like cross-engine re-run that C1 was missing. **One documented query form
per engine, same shape, same instance type, all four engines re-measured on current
versions.** This supersedes the Aug-27 cross-engine table, whose harness was lost and
whose query form is unrecoverable.

## Rig and protocol

EC2 **r6id.4xlarge** (16 vCPU / **8 physical cores**, 123 GB, local NVMe),
PostgreSQL **17.10**, `shared_buffers = 16GB`, `max_connections = 200`, one dedicated
instance per engine. 2,188,038 Wikipedia articles, index on `content` only.

`pgbench`, **1 / 8 / 16 / 32 clients**, **30 s per (band, client-count)**,
`-j = min(clients, 8)`. Each band warmed before timing and `EXPLAIN`-verified to use
the intended index.

**Query form, fixed across engines** (verbatim, so this run is reproducible):

| engine | ranked band |
|---|---|
| pg_fts | `SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','T') ORDER BY d <=> to_ftsquery('english','T') LIMIT 10) s` |
| pg_textsearch | `SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> 'T'::bm25query LIMIT 10) s` |
| pg_search | `SELECT count(*) FROM (SELECT id FROM docs WHERE content @@@ 'T' ORDER BY paradedb.score(id) DESC LIMIT 10) s` |
| vchord | `SET "bm25.limit"=10; SELECT count(*) FROM (SELECT id FROM docs ORDER BY tv <&> to_bm25query(to_tsvector('english','T'),'docs_vc') LIMIT 10) s` |

The `count(*) FROM (...)` wrapper is deliberate: every engine returns exactly one row,
so pgbench measures identical client-side work and the comparison is not skewed by
result transfer.

Versions: pg_fts **1.6.1**; pg_textsearch `3c77689` (1.5.0-dev); pg_search **0.25.6**
(paradedb, pgrx 0.19.2); VectorChord-bm25 `14fc2a3` (pgrx 0.17.0).

---

## rare_k10 (`slovakia`, df 10,875)

| engine | @1 | @8 | @16 | @32 | 1→32 |
|---|---|---|---|---|---|
| pg_fts | 101 tps / 9.9 ms | 802 / 10.0 | 1,080 / 14.8 | 1,076 / 29.7 | **10.7×** |
| pg_textsearch | **1,189 / 0.8** | **8,399 / 1.0** | **8,451 / 1.9** | **8,349 / 3.8** | 7.0× |
| pg_search | 456 / 2.2 | 3,506 / 2.3 | 4,362 / 3.7 | 4,364 / 7.3 | 9.6× |
| vchord | 516 / 1.9 | 1,295 / 6.2 | 1,254 / 12.8 | 1,234 / 25.9 | 2.4× |

## common_k10 (`year`, df 734,896)

| engine | @1 | @8 | @16 | @32 | 1→32 |
|---|---|---|---|---|---|
| pg_fts | 21 tps / 47.9 ms | 168 / 47.7 | 206 / 77.6 | 208 / 153.6 | **10.0×** |
| pg_textsearch | 93 / 10.8 | 695 / 11.5 | 696 / 23.0 | 683 / 46.9 | 7.4× |
| pg_search | **447 / 2.2** | **3,558 / 2.2** | **4,311 / 3.7** | **4,298 / 7.4** | 9.6× |
| vchord | 249 / 4.0 | 538 / 14.9 | 501 / 31.9 | 499 / 64.1 | 2.0× |

## count_common — exact `count(*)` of a 734,896-match term

| engine | @1 | @8 | @16 | @32 | 1→32 |
|---|---|---|---|---|---|
| **pg_fts** | **455 tps / 2.2 ms** | **3,583 / 2.2** | **2,934 / 5.5** | **2,923 / 10.9** | 6.4× |
| pg_search | 78 / 12.8 | 405 / 19.8 | 450 / 35.5 | 513 / 62.3 | 6.6× |
| pg_textsearch | — | — | — | — | no count/df function |
| vchord | — | — | — | — | ranking-only |

**pg_fts is 5.7× pg_search's throughput at 32 clients** on this band (2,923 vs 513 tps)
and 5.7× lower latency (10.9 vs 62.3 ms), and the other two cannot do it at all.

## Index size and build

| | pg_fts | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| index | **1,421 MB** | 1,887 MB | 2,957 MB | 2,902 MB |
| build | 501 s | 510 s | **120 s** | **56 s** |

---

## What this establishes

**1. Nobody collapses. All four saturate.** Every engine rises steeply to 8 clients
then flattens; latency roughly doubles per client doubling beyond that. On a
**16-vCPU / 8-physical-core** host, 8 concurrent backends plus pgbench's 8 threads
already subscribe the machine, so the plateau is host-CPU-bound rather than an engine
scalability limit. That caveat applies equally to all four and does not affect the
comparison.

**2. Correction: my "vchord collapses" claim was wrong.** I published, from the Aug-27
data, that vchord's throughput *collapses* under concurrency. Re-measured, it **peaks at
8 clients then declines 4.7% (rare) / 7.2% (common) by 32** — a saturation plateau, not
a cliff. The vchord arm settled it with a peak-locating sweep (c=2/4/12/24/48 →
823/1,107/1,289/1,237/1,230 tps: a flat top, no cliff) and `mpstat` (49.7% CPU at c=8
with 8 physical cores busy, 99.8% at c=32). The earlier "collapse" was the same
peak-then-decline read without CPU data, and on current versions the decline is half as
steep (was −12.2%, now −4.7%). Its 1→32 factor is genuinely the lowest (2.0–2.4×), but
that is because **one client already consumes a full core**, not because it degrades.

**3. pg_fts has the best scaling factor and the worst absolute ranked throughput.**
10.7×/10.0× scaling is the highest of the four — we are the most idle-parallel, with
latency *flat* from 1 to 8 clients (9.9 → 10.0 ms) while throughput rises 8×. But we
start from the lowest base, so absolute ranked tps is last: at 32 clients we do 1,076
tps on rare where pg_textsearch does 8,349 (7.8×) and 208 on common where pg_search does
4,298 (**20.7×**).

**4. The common-term gap is worse under concurrency than single-client.** Single-client
latency was 36.16 ms vs pg_search's 2.12 (17×). As throughput at 32 clients it is
**20.7×**. Good scaling does not rescue it — it multiplies a slow per-query cost. This
strengthens the case for ROADMAP 4a rather than deferring it, and it is the clearest
argument yet that the sidecar gap-decode cost is the thing to fix.

**5. Our standout is unchanged and now demonstrated under load:** exact `count(*)` at
2,923 tps / 10.9 ms at 32 clients, 5.7× pg_search, unavailable in the other two. Plus
the smallest index (1,421 MB, 25% under next best, 2.1× under pg_search).

## Caveats

- The 8-core saturation ceiling bounds every engine; a larger host would raise all four
  plateaus and might reorder them. This run answers "does anyone fall over" (no) and
  "how do they compare on identical hardware", not "what is each engine's peak".
- pg_search returns **495,580** matches for `year` where the correct English answer is
  **734,896** — Tantivy does not stem. It is doing materially less work per query on the
  common band, which is part of its advantage there.
- pg_textsearch's `count_common` and vchord's are absent by capability, not by omission.

## Data

`bench/data_c1x_2026-09-11/{pg_fts,pg_textsearch,pg_search,vchord}.json`. Harness
`bench/underload.sh`.

## Process notes

- Two harness/rig defects were found and fixed during this run: `git archive` excludes
  `bench/` (`.gitattributes` `export-ignore`), so the harness had to be copied directly
  — this cost one wasted pg_fts run; and `grep -q "shared_preload_libraries"` matched the
  *commented* default line, so pg_search's preload was silently skipped and its first
  attempt produced all zeros.
- `underload.sh` now **abandons a band that yields no tps** instead of recording `0` —
  the zeros above would otherwise have looked like a measured result.
- The pg_search agent died immediately after its Rust build (the second time on this
  task); its host was intact so the arm was completed by hand rather than rebuilt.
