# pg_fts 1.13.0 vs pg_textsearch on EC2 metal, Fedora 44, XFS on local NVMe (2026-10-15)

Protocol: `PROTOCOL_PGTS_METAL_2026-10-15.md`, written before the run, with 7 amendments
recorded in it.  Amendments 1-5 came from a 50k-row smoke test; 6 and 7 were added
during the run, before any comparison was read.  Raw data, harness and analysis scripts:
`data_pgts_metal_2026-10-15/`.

## What was compared

| arm | build | identity |
|---|---|---|
| **pg_fts 1.13.0** | release, PGXN zip | sha256 `47e24fd4...be55`, verified on each host |
| **pg_textsearch HEAD** | `~/src/pg_textsearch` at `a5fdfeb1` (`v1.5.0-4-ga5fdfeb1`, `default_version 1.6.0-dev`) | `git archive` of that commit |
| **pg_textsearch 1.5.1** | the latest release tag (`fa142d04`) | `git archive` of the tag |

Every arm ran on every host: 2x c6id.metal (Intel Xeon Platinum 8375C, 2 sockets, 128
vCPU, 256 GiB) and 2x c7gd.metal (Graviton3 Neoverse-V1, 1 socket, 64 vCPU, 128 GiB).
The setup on each host:
- Fedora Linux 44 Cloud (kernel `7.2.10-200.fc44`).
- XFS on one local NVMe instance-store device, mounted `noatime`.
- PostgreSQL 17.10 built from source with identical flags.  Each arm had its own copy
  of the same build (all three `postgres` binaries had the same md5) and its own data
  directory, with identical settings: `shared_buffers=32GB`, `jit=off`,
  `autovacuum=off`, and `shared_preload_libraries` = `pg_prewarm` plus `pg_textsearch`
  for its arms.
- The 2,188,038-article Wikipedia corpus; the TSV md5 `f5939e85...` matched on all 4
  hosts.

One cluster ran at a time, and arms were rotated per pass.

## Correctness first

Every band returned k rows, or the full match set, on every arm.  pg_textsearch's
filtered bands that hit the 300 s timeout are reported as timeouts.

The exact count of `year` was 734,896 on all three arms, so the two engines tokenize
this term identically.

**Ranking agreement** (identical on all 4 hosts; `agree.py`): the two pg_textsearch arms
return identical top-10 and top-100 id lists for every query.  For pg_fts vs
pg_textsearch:

| query | top-10 overlap | top-100 overlap | common-formula score sum, top-100 (pg_fts / pg_textsearch) |
|---|---|---|---|
| `slovakia` | 8/10 | 92/100 | 1078.73 / 1077.83 |
| `hungary` | 8/10 | 90/100 | 931.25 / 930.59 |
| `year` | 6/10 | 89/100 | 232.60 / 232.44 |
| `slovakia \| hungary` | 7/10 | 90/100 | 1802.11 / 1799.61 |
| `film \| music \| album \| band` | 8/10 | 81/100 | 1871.80 / 1868.00 |

Both engines use the same BM25: k1 = 1.2, b = 0.75 and the same Lucene IDF (read from
both sources).  They differ in how they quantize document length: pg_fts's v4 sidecar
byte and pg_textsearch's fieldnorm byte are different encodings.  Near the cut-off,
where scores are close, that difference reorders documents.

To check that neither engine is mis-ranking, every returned list was rescored with
**one** formula: `fts_bm25` with exact document lengths and the corpus N and avgdl.
Under that formula pg_fts's top-100 scores marginally higher for every query, by 0.07-0.20%.
So both engines return near-optimal lists for the exact formula, and the
non-overlapping ids are documents tied within quantization error.  This is a check of
semantics, not a relevance claim; there are no relevance judgements for this corpus.

## Single-client latency

All figures are ms; each cell is the median of the 3 pass medians for host 1 / host 2.
"Called" means that on BOTH hosts the pass spreads of pg_fts and pg_textsearch HEAD do
not overlap.  pg_textsearch 1.5.1 is within a few percent of HEAD on every band, on
both architectures.

#### x86_64, c6id.metal

| band | pg_fts 1.13.0 | pg_textsearch HEAD | pg_textsearch 1.5.1 | called |
|---|---|---|---|---|
| rare `slovakia` k10 | 0.32 / 0.50 | 2.09 / 2.03 | 2.11 / 2.06 | pg_fts faster |
| mid `hungary` k10 | 0.68 / 0.65 | 2.38 / 2.38 | 2.52 / 2.40 | pg_fts faster |
| common `year` k10 | 0.77 / 0.80 | 10.1 / 10.1 | 9.98 / 9.97 | pg_fts faster |
| common k100 | 1.33 / 1.22 | 12.2 / 12.2 | 12.0 / 12.0 | pg_fts faster |
| common k1000 | 14.4 / 14.2 | 14.7 / 14.5 | 14.5 / 14.3 | **no difference** |
| OR `slovakia \| hungary` | 1.70 / 1.73 | 2.77 / 2.70 | 2.69 / 2.60 | pg_fts faster |
| OR `film \| music \| album \| band` | 15.9 / 15.9 | 16.1 / 16.1 | 16.0 / 16.1 | **no difference** |
| AND `slovakia & hungary` | 1.08 / 0.99 | >300 s (CTE form: 4.1 s / 4.1 s) | >300 s (CTE: 4.1 s / 4.1 s) | pg_fts faster |
| AND `united & states` | 2.79 / 2.83 | >300 s (CTE: 288 s / 287 s) | >300 s (CTE: 286 s / 287 s) | pg_fts faster |
| NOT `hungary & !slovakia` | 2.37 / 2.47 | >300 s (CTE: 16.0 s / 16.0 s) | >300 s (CTE: 16.0 s / 16.0 s) | pg_fts faster |
| phrase `"united states"` | 3.37 / 3.38 | >300 s (CTE: >300 s) | >300 s (CTE: >300 s) | pg_fts faster |
| phrase `"world war"` | 7.43 / 7.46 | >300 s (CTE: 260 s / 260 s) | >300 s (CTE: 260 s / 259 s) | pg_fts faster |
| exact count of `year` | 0.77 / 0.68 | 243 s / 243 s | 243 s / 243 s | pg_fts faster |

#### aarch64, c7gd.metal

| band | pg_fts 1.13.0 | pg_textsearch HEAD | pg_textsearch 1.5.1 | called |
|---|---|---|---|---|
| rare `slovakia` k10 | 0.23 / 0.23 | 1.12 / 0.96 | 0.97 / 0.95 | pg_fts faster |
| mid `hungary` k10 | 0.24 / 0.24 | 1.33 / 1.19 | 1.18 / 1.17 | pg_fts faster |
| common `year` k10 | 0.34 / 0.33 | 10.7 / 10.5 | 10.5 / 10.5 | pg_fts faster |
| common k100 | 0.76 / 0.75 | 12.9 / 12.8 | 12.8 / 12.8 | pg_fts faster |
| common k1000 | 11.5 / 11.5 | 14.8 / 14.7 | 14.7 / 14.7 | pg_fts faster |
| OR `slovakia \| hungary` | 1.28 / 1.28 | 1.44 / 1.26 | 1.26 / 1.25 | **no difference** |
| OR `film \| music \| album \| band` | 12.5 / 12.5 | 14.0 / 13.9 | 13.9 / 14.0 | pg_fts faster |
| AND `slovakia & hungary` | 0.63 / 0.62 | >300 s (CTE: 3.9 s / 3.9 s) | >300 s (CTE: 3.9 s / 3.9 s) | pg_fts faster |
| AND `united & states` | 1.87 / 1.86 | >300 s (CTE: 267 s / 268 s) | >300 s (CTE: 268 s / 268 s) | pg_fts faster |
| NOT `hungary & !slovakia` | 1.64 / 1.65 | >300 s (CTE: 14.9 s / 14.9 s) | >300 s (CTE: 14.9 s / 14.9 s) | pg_fts faster |
| phrase `"united states"` | 2.32 / 2.35 | >300 s (CTE: >300 s) | >300 s (CTE: >300 s) | pg_fts faster |
| phrase `"world war"` | 5.84 / 5.80 | >300 s (CTE: 243 s / 243 s) | >300 s (CTE: 243 s / 243 s) | pg_fts faster |
| exact count of `year` | 0.16 / 0.16 | 228 s / 228 s | 228 s / 228 s | pg_fts faster |

How to read the pg_textsearch filtered bands:
- **Single-query form.**  pg_textsearch documents the filtered form `WHERE content @@
  to_tsquery(...) ORDER BY content <@> ... LIMIT`.  Its planner runs it as a sequential
  scan with a filter, then a sort, even with `enable_seqscan = off`, so every execution
  hit the 300 s timeout on both architectures.
- **CTE form.**  The fastest form found was a `MATERIALIZED` CTE, which does put the
  `@@` filter through the bm25 index.  The time then scales with the number of
  matches: about 6,600 for `slovakia & hungary` against hundreds of thousands for
  `united & states` and `"world war"`.  Each match is re-tokenized and scored, which
  is what pg_textsearch's README says: Boolean filtering with ranking "is not yet
  optimized as a single index scan".
- **Exact count.**  pg_textsearch has no index-only count; `count(*) WHERE @@` is a
  parallel sequential scan.

The x86 `rare` row shows pg_fts at 0.32 on one host and 0.50 on the other: host 1's
three pass medians were 0.51, 0.27 and 0.32, and host 2's were 0.47-0.51.  Under 0.5 ms
the per-pass variation on the 2-socket host is larger than on Graviton.  pg_textsearch
on the same band was 1.96-2.32 on both hosts, so the call stands.

**Not normalised for cache warmth inside a pass.**  The first execution of each band
(discarded from the median) is slower for pg_fts than for pg_textsearch on single-term
bands: 36-64 ms against 9-14 ms for rare k10 on x86, and 16-39 ms against 3-4 ms on
arm.  pg_fts's first ranked query in a backend builds its per-backend dictionary and
doclen directories (I7, 1.12.0), and pg_textsearch has no comparable per-backend
build.  The cold-cache band below measures the first query after a restart directly.

## Throughput (settled, tps)

Median of 2 passes; 30 s per point; all four bands reported for every arm.
pg_textsearch's AND and count bands were skipped because their latency was over 1 s
(amendment 7).

| band | clients | pg_fts x86 h1 / h2 | pgts HEAD x86 | pg_fts arm h1 / h2 | pgts HEAD arm |
|---|---|---|---|---|---|
| rare k10 | 1 | 4,702 / 4,310 | 1,223 / 1,259 | 4,556 / 4,645 | 969 / 876 |
| rare k10 | 16 | 65,051 / 68,587 | 16,077 / 15,721 | 62,176 / 63,917 | 13,171 / 10,597 |
| rare k10 | 64 | 143,628 / 143,726 | 21,754 / 21,428 | 149,660 / 148,392 | 20,004 / 18,323 |
| rare k10 | 128 | 139,730 / 150,569 | 17,281 / 18,954 | 145,547 / 144,189 | 20,243 / 19,127 |
| rare k10 | 256 | 125,557 / 125,691 | 16,280 / 17,456 | 143,784 / 141,318 | 20,269 / 19,094 |
| common k10 | 1 | 3,155 / 3,193 | 123 / 122 | 3,339 / 3,014 | 95 / 94 |
| common k10 | 64 | 100,162 / 109,162 | 1,437 / 1,541 | 155,639 / 105,607 | 3,563 / 3,471 |
| common k10 | 128 | 177,737 / 179,467 | 1,457 / 1,432 | 136,220 / 99,785 | 3,600 / 3,528 |
| AND `united & states` | 64 | 26,369 / 26,345 | n/a (>300 s) | 29,909 / 28,195 | n/a |
| AND `united & states` | 128 | 34,069 / 34,188 | n/a | 28,548 / 28,767 | n/a |
| exact count | 128 | 383,306 / 382,993 | n/a (228-243 s) | 294,530 / 296,348 | n/a |

pg_textsearch 1.5.1 is within the HEAD arm's spread on every throughput point
(`tps.txt`).  pg_fts common k10 on arm differs between the hosts at 64-256 clients
(155,639 vs 105,607 at 64): same host type, same binary, same index files.  This is the
host-state effect documented in `RESULTS_TPS_VARIANCE_2026-10-09.md`.  The mbench2
chase read 115.8 vs 116.0 ns, so it did not detect it.  The call does not depend on
it: pg_textsearch's numbers are 28-44x lower at these points on both hosts (ma1 43.7x and ma2 30.4x at 64 clients; ma2 28.3x at 128).

## Cold cache (first query after stopping PG and dropping the OS cache; median of 5; ms)

| band | pg_fts x86 h1 / h2 | pgts HEAD x86 | pgts 1.5.1 x86 | pg_fts arm | pgts HEAD arm | pgts 1.5.1 arm |
|---|---|---|---|---|---|---|
| rare k10 | 60.6 / 61.8 | 41.2 / 37.3 | 27.8 / 31.1 | 48.9 / 52.4 | 12.7 / 24.6 | 12.9 / 20.7 |
| common k10 | 76.1 / 76.8 | 54.2 / 49.2 | 49.4 / 49.2 | 55.0 / 60.3 | 24.9 / 36.6 | 24.9 / 36.4 |
| AND k10 | 73.6 / 81.7 | CTE 6,307 / 6,483 | CTE 6,290 / 6,392 | 60.5 / 66.9 | CTE 4,860 / 5,124 | CTE 4,810 / 5,072 |

**pg_textsearch is faster on a cold single-term query**, by 19-33 ms on x86 and 24-36 ms
on arm.  pg_fts's first query reads its directories from disk to build the per-backend
caches (I7), which the warm numbers above amortise.  On a cold AND, pg_fts is two orders
of magnitude faster.

## Build and size

| | pg_fts 1.13.0 | pg_textsearch HEAD | pg_textsearch 1.5.1 |
|---|---|---|---|
| build, default index (s) x86 h1 / h2 | 213.5 / 216.0 | 249.8 / 252.8 | 254.4 / 252.8 |
| build (s) arm h1 / h2 | 219.3 / 219.8 | 258.5 / 257.6 | 258.1 / 257.6 |
| index size | **1,369 MiB** | 1,887 MiB | 1,887 MiB |
| `positions = on` index (phrase bands) build / size | 261-271 s / 2,572 MiB | n/a | n/a |

All builds used each engine's default parallel build, with
`max_parallel_maintenance_workers = 8`.  pg_fts is built as an expression index
(`to_ftsdoc('english', content)`).  `fts_vacuum` after the build took 0.02-0.05 s and
changed nothing: since 1.11.0 a plain build packs itself.

pg_textsearch answers phrases from its single index and a heap recheck.  pg_fts needs
its second, `positions = on` index for index-only phrases; with only the default index,
phrases are rechecked on the heap (not measured in this run).

## Concurrent writes

8 clients inserting single-row autocommit documents, 8 clients running rare k10, 120 s;
pg_fts also ran `fts_merge` every 30 s.

| | pg_fts insert tps | pg_fts query tps | pgts HEAD insert | pgts HEAD query | pgts 1.5.1 insert | pgts 1.5.1 query |
|---|---|---|---|---|---|---|
| x86 h1 | 55,010 | 56 | 8,684 | 1,394 | 10,925 | 1,148 |
| x86 h2 | 39,340 | 221 | 15,175 | 1,602 | 8,688 | 1,089 |
| arm h1 | 55,590 | 62 | 18,936 | 1,028 | 19,687 | 1,069 |
| arm h2 | 55,559 | 59 | 19,630 | 867 | 21,424 | 819 |

**Correctness held on every arm and host:** after each run, the number of rows the
index finds by ranked retrieval of the unique token equals the heap count of inserted
rows (6.67M on pg_fts arm h1; 3.23M on pg_textsearch HEAD arm h1).

**The two engines make opposite trade-offs under this load.**  pg_fts inserts 2.6-6.3x
faster, but its concurrent ranked query runs at 56-221 tps against pg_textsearch's
819-1,602.  The inserts land in pg_fts's pending list, which every ranked query has
read since 1.13.0 (CHANGELOG 1.13.0): 120 s at 55k tps is 6.6M pending documents
between merges.  Since 1.13.0 the cost of reading them is linear rather than quadratic,
but it is still paid on every query.  pg_textsearch keeps its writes in an in-memory
memtable.  This is a real weakness of pg_fts in this workload: a sustained 50k inserts/s
with concurrent ranked reads.  It is not visible in any read-only band.  The fix
direction (a bounded pending list, or merges driven by its size) is open (ROADMAP I12).

## Summary

On 2x c6id.metal and 2x c7gd.metal, Fedora 44, XFS on local NVMe, Wikipedia 2.19M:

- **Warm single-client latency.**
  - pg_fts is faster on 11 of 13 bands on x86 and 12 of 13 on arm, with the call made
    on both hosts.  The bands with no difference were common k1000 and the 4-term OR
    on x86, and the 2-term OR on arm.
  - Single terms (k10, k100): 3.5-13x on x86 and 4-32x on arm; for example common k10
    is 0.34 vs 10.5 ms on arm.
  - Filtered (AND, NOT, phrase) and exact count: pg_fts answers in 0.6-7.5 ms.
    pg_textsearch takes 4 s to over 300 s, because it has no single-index-scan path for
    a filter with ranking, nor an index-only count.
- **Settled throughput.**  pg_fts is 3.4-8.1x higher on rare k10, and 26-150x higher on
  common k10, at every client count on all 4 hosts.
- **Build and size.**  pg_fts builds about 14-15% faster and its index is 27% smaller.
  pg_fts's phrase index is an extra 2.5 GiB.
- **Cold first query.**  pg_textsearch is faster on single terms, by 19-36 ms.
- **Concurrent writes.**  pg_fts takes 2.6-6.3x more inserts, but its ranked queries
  under that insert load are 5-25x slower than pg_textsearch's.
- **pg_textsearch HEAD vs 1.5.1.**  No measurable difference on any band.

## What this does not claim

Relevance quality; any engine other than these two (the README's pg_search, VectorChord
and GIN figures are the 1.11.0 run); network storage; tuned NUMA placement; and any
number from another day or host.
