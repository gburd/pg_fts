# pg_fts 1.18.0 vs the field on EC2 metal, PG 18.7 and 19.0 (2026-11-19/20)

Protocol, written before any host was launched, with five amendments from the smoke test:
`PROTOCOL_FIELD_METAL_2026-11-19.md`.  Raw output from all four hosts, the harness, and the
generated tables: `data_field_metal_2026-11-19/` (`tables.md` is `harness/analyze.py`'s full
output; every number below comes from it, `harness/headline.py` or `harness/agree_sum.py`).

## What ran

| | |
|---|---|
| hosts | 2x c6id.metal (Xeon 8375C, 128 vCPU, 251 GiB) and 2x c7gd.metal (Graviton3, 64 vCPU, 125 GiB), us-east-2c |
| OS, disk | Fedora 45 (kernel 7.3.4), XFS `noatime` on one local NVMe instance-store device |
| PostgreSQL | 18.7 and 19.0 from source, `-O2 -g -fno-omit-frame-pointer`, no asserts; one build per major, copied per arm (one postgres md5 per major on every host) |
| settings | shared_buffers 32GB, work_mem 256MB, maintenance_work_mem 8GB, jit off, autovacuum off |
| corpus | 2,188,038 Wikipedia articles, md5 `f5939e85...` on every host |
| preflight | THP never, governor performance, Intel turbo off; a 4 GiB pointer chase before and after each phase (133-134 ns x86, 151 ns arm, no drift) |

Arms on 18.7: pg_fts **1.18.0** (PGXN zip sha256 `567dde01...`, checked on the host),
pg_textsearch **1.5.1** (fa142d04), pg_textsearch **main** (8923a5ba, 1.6.0-dev),
pg_search **0.27.0** (the ParadeDB el10 RPM, with pgvector v0.8.7) as shipped and with
`pnorms=true`, VectorChord-bm25 **0.3.0** with pg_tokenizer 0.1.1 (release zips), and
**GIN** on a stored `tsvector` column ranked with `ts_rank`.  Arms on 19.0: pg_fts,
pg_textsearch main, and GIN.  pg_textsearch 1.5.1 does not compile on 19.0; pg_search and
VectorChord do not ship for it.

Each arm had its own prefix, data directory and copy of the table; one cluster ran at a
time.  Latency: 5 passes, arm order rotated each pass, 8 executions per band in one
session, median of the last 5 (bands over 10 s: median of 3; over 60 s: one; 300 s
statement timeout, not retried).  An A/A arm (a second pg_fts slot on the same cluster)
sat opposite pg_fts in the rotation.  Throughput: settled (CHECKPOINT, 60 s idle,
prewarm), pgbench 30 s at 1/16/64/128/256 clients, two passes in opposite arm order.
Cold: server restart plus `drop_caches`, 5 repetitions.

## Correctness

- **Counts.**  pg_fts, both pg_textsearch builds and GIN agree exactly on every host and
  both majors: `slovakia` 10,875, `hungary` 24,097, `year` 734,896.  pg_search counts
  10,898 / 24,152 / 735,955 (its tokenizer is not PostgreSQL's `english`).  The regex
  ground truth is 10,898 / 24,148 / 733,960 (`years?` for the stemmed term).
- **Rows.**  Every band returned k rows (or its count) on every arm that finished it,
  except VectorChord's common top-1000, which returned 100 rows on every pass and host.
  Its `bm25_catalog.bm25_limit` setting (present in the 0.3.0 library; default not
  checked) caps the result.  Under gate 2 that band is reported as "short", with no
  time or ratio.
- **19.0 vs 18.7.**  pg_fts's and pg_textsearch main's top-10/100 ids on 19.0 are
  identical to their 18.7 ids on every host (protocol gate 6).
- **Not done.**  Gate 4, pg_fts's top-k against its exhaustive references
  (`mt_oracle_idx.py`, `and_oracle_idx.py`), was not in the harness and did not run.
  The agreement rescore below is the only check of pg_fts's ranked output in this run.
  The 1.18.0 release gate covered ranked correctness, but not on these hosts.
- **Agreement** (`harness/agree_sum.py`; top-k rescored under one formula, `fts_bm25`
  with exact lengths and the corpus N and avgdl; pg_fts's own overlap is 10/10 and
  100/100 by construction):

  | query, k | pg_fts | pg_textsearch (both) | pg_search (both) | VectorChord | GIN |
  |---|---|---|---|---|---|
  | slovakia, 100 | 1078.73 | 1077.83 (92) | 1078.32 (95) | 1077.47 (91) | 968.81 (28) |
  | hungary, 100 | 931.25 | 930.59 (90) | 930.29 (92) | 929.49 (86) | 832.06 (20) |
  | year, 100 | 232.60 | 232.44 (89) | 232.59 (96) | 232.45 (89) | 211.56 (11) |
  | slovakia hungary, 100 | 1802.11 | 1799.61 (90) | 1801.56 (95) | 1798.16 (86) | 1357.89 (20) |
  | film music album band, 100 | 1871.80 | 1868.00 (81) | 1871.74 (90) | 1867.73 (80) | 1550.58 (3) |

  (overlap with pg_fts's top-100 in parentheses).  The four BM25 engines' top-100 lists
  score within 0.06-0.22% of each other under the common formula, so the differing ids
  are near-ties, as in every earlier run.  `ts_rank` is not BM25, and its lists score
  10-27% lower.  pg_search's two arms return the same ids.  On some queries their tie
  order differs between hosts (the score sums are identical on all four).  GIN's `year`
  order also differs by host.

## Latency (ms, single client; range over the two hosts of each architecture, x86 / arm)

### PostgreSQL 18.7

| band | **pg_fts 1.18.0** | pg_textsearch 1.5.1 | pg_textsearch main | pg_search 0.27.0 | pg_search pnorms | VectorChord | GIN + ts_rank |
|---|---|---|---|---|---|---|---|
| rare top-10 | **0.23 / 0.24** | 0.91 / 0.98-0.99 | 0.92 / 0.98-0.99 | 1.18 / 1.19-1.20 | 1.04 / 1.02-1.06 | 8.7-8.8 / 11.2-11.3 | 55 / 42-43 |
| mid top-10 | **0.25 / 0.25** | 1.12 / 1.19-1.21 | 1.11-1.12 / 1.20-1.21 | 1.17-1.20 / 1.09-1.16 | 1.02-1.06 / 1.03-1.04 | 16.6-16.9 / 21.7-21.8 | 138-150 / 112-113 |
| common top-10 | **0.36 / 0.35** | 9.9 / 10.7-10.8 | 10.1 / 10.9 | 1.22-1.26 / 1.22-1.24 | 1.18-1.23 / 1.17-1.20 | 55 / 68 | 2,347-2,672 / 1,699-1,712 |
| common top-100 | **0.81 / 0.80-0.81** | 12.0-12.1 / 13.1 | 12.3-12.4 / 13.3 | 2.45-2.56 / 2.58-2.59 | 2.01-2.08 / 1.97-2.06 | 58-59 / 70 | 2,351-2,734 / 1,685-1,710 |
| common top-1000 | 13.4 / 11.8 | 14.0 / 15.1-15.2 | 14.2-14.3 / 15.3 | 7.6-7.8 / 8.4-8.5 | **5.8-5.9 / 5.7** | short (100 rows) | 2,345-2,704 / 1,708-1,709 |
| 2-term OR | 1.31 / 1.30-1.31 | **1.28-1.29 / 1.27** | 1.29-1.30 / 1.27-1.28 | 1.81-1.83 / 1.80-1.81 | 1.62-1.63 / 1.55-1.56 | 5.6-5.7 / 7.0-7.1 | 167-168 / 140 |
| 4-term OR | 15.7 / 12.6 | 15.8 / 13.9-14.1 | 15.8 / 14.0 | 10.4-10.6 / 9.2-9.3 | **10.1-10.2 / 9.1-9.2** | 32 / 37 | 1,719-1,726 / 1,245-1,258 |
| `slovakia & hungary` | **0.67 / 0.64-0.65** | 4,961-4,966 cte / 3,957-3,958 cte | 4,964-4,967 cte / 3,950-3,957 cte | 1.60-1.61 / 1.60-1.62 | 1.38 / 1.34-1.35 | n/a | 19 / 19-20 |
| `united & states` | **2.16 / 1.89-1.93** | >300 s / 274.5 s cte | >300 s / 273-275 s cte | 9.2 / 8.6-8.8 | 9.2-9.5 / 8.6-8.8 | n/a | 1,583-2,712 / 1,869-1,875 |
| `world & war` | 6.27 / 5.52-5.54 | 189.5 s cte / 150.2 s cte | 189.7-189.9 s cte / 149.8-150.1 s cte | 2.85-2.93 / 2.85-2.98 | **2.18-2.27 / 2.26-2.35** | n/a | 1,123-1,231 / 926-934 |
| `hungary & !slovakia` | 1.81-1.82 / 1.67 | 19.3 s cte / 15.3 s cte | 19.3 s cte / 15.2-15.3 s cte | 1.63-1.67 / 1.53-1.61 | **1.52-1.54 / 1.45-1.51** | n/a | 113-121 / 99-100 |
| `"united states"` | **2.56-2.57 / 2.38-2.44** | >300 s | >300 s | 8.9-9.0 / 8.7-8.9 | 9.4-9.6 / 8.6-8.9 | n/a | 2,090-3,294 / 2,642-2,655 |
| `"world war"` | **6.59-6.61 / 5.88-5.92** | >300 s / 248.4-248.7 s cte | >300 s / 248.4-248.6 s cte | 9.0-9.4 / 8.6-8.8 | 9.3 / 8.5-8.7 | n/a | 1,485-1,544 / 1,239-1,251 |
| exact count of `year` | **0.18 / 0.16** | 290.7-290.9 s / 232.8-232.9 s | 291.0-291.1 s / 232.3-232.7 s | 0.95-0.96 / 0.90-0.91 | 0.96-0.99 / 0.91-0.93 | n/a | 552-578 / 400-406 |

"cte" is pg_textsearch's filtered query rewritten as a materialized CTE, which runs
where its plain form takes over 300 s; the faster of the two is shown.  Its plain
boolean and phrase forms are sequential scans with a `to_tsquery` filter (it has no
index path for them).  VectorChord has no boolean, phrase or count form.  Phrases
in pg_fts use its second (`positions = on`) index.

### PostgreSQL 19.0

| band | **pg_fts 1.18.0** | pg_textsearch main | GIN + ts_rank |
|---|---|---|---|
| rare top-10 | **0.22-0.23 / 0.23-0.24** | 0.91-0.92 / 0.97-0.99 | 53-55 / 42-43 |
| mid top-10 | **0.25 / 0.26** | 1.11 / 1.19-1.20 | 140-146 / 111 |
| common top-10 | **0.34-0.36 / 0.35** | 9.9-10.0 / 10.9 | 3,715-3,999 / 2,661-2,701 |
| common top-100 | **0.80-0.81 / 0.79** | 12.1 / 13.3 | 3,611-3,648 / 2,658-2,706 |
| common top-1000 | **13.4 / 11.6-11.8** | 14.1 / 15.2-15.3 | 3,441-3,729 / 2,675-2,710 |
| 2-term OR | 1.28-1.32 / 1.29 | 1.27-1.30 / 1.26-1.28 | 155-164 / 138 |
| 4-term OR | 15.6-15.8 / **12.6** | 15.7 / 14.1 | 1,515 / 1,140-1,161 |
| `slovakia & hungary` | **0.66 / 0.63** | 5.2 s cte / 4.0 s cte | 18.5-19.1 / 19.2-19.4 |
| `united & states` | **2.13-2.15 / 1.87-1.88** | >300 s / 278 s cte | 2,504-2,641 / 1,125-1,888 |
| `world & war` | **6.25-6.26 / 5.48-5.49** | 199.3-199.5 s cte / 152.3 s cte | 1,084-1,237 / 923-926 |
| `hungary & !slovakia` | **1.80-1.82 / 1.66-1.67** | 20.3 s cte / 15.5 s cte | 113-114 / 98 |
| `"united states"` | **2.54 / 2.31-2.32** | >300 s | 3,236-3,440 / 1,440-2,657 |
| `"world war"` | **6.59-6.61 / 5.82-5.84** | >300 s / 252 s cte | 1,452-1,459 / 1,241-1,245 |
| exact count of `year` | **0.17 / 0.16** | >300 s / 235.9 s | 535-536 / 2,015-2,041 |

### Verdicts

For every band and engine, `tables.md` gives the engine/pg_fts ratio of medians with a
bootstrap 95% CI over both hosts' pass-medians, and a verdict.  STABLE means the pass
spreads separate on both hosts and the effect exceeds 3x the A/A spread.  The A/A spread
was 0.0-4.5% per band (the largest on the arm rare top-10 on 18.7).  Every ratio quoted here is STABLE on both architectures unless marked
otherwise:

- **pg_fts vs pg_textsearch (1.5.1 and main):**
  - pg_fts is faster on rare (3.9-4.1x), mid (4.4-4.9x) and common top-10 (27.5-31.1x)
    and top-100 (14.8-16.8x);
  - pg_fts is faster on common top-1000 (1.05x x86, 1.29-1.30x arm), and on the 4-term
    OR on arm (1.11-1.12x);
  - **no claim** on the 2-term OR on either architecture (NOISY on x86 on 18.7, NO CLAIM
    elsewhere), nor on the 4-term OR on x86;
  - every boolean, phrase and count band is three to six orders of magnitude, or over
    300 s.
- **pg_fts vs pg_search 0.27.0, as shipped:**
  - pg_fts is faster on rare (4.9-5.1x), mid (4.4-4.8x), common top-10 (3.4-3.5x) and
    top-100 (3.0-3.2x);
  - pg_fts is faster on the 2-term OR (1.38-1.40x), `slovakia & hungary` (2.4-2.5x),
    `united & states` (4.3-4.6x), `"united states"` (3.5-3.6x), `"world war"`
    (1.37-1.49x) and the exact count (5.4-5.6x);
  - **pg_search is faster** on common top-1000 (pg_fts 1.4-1.8x slower), the 4-term OR
    (1.35-1.5x), `world & war` (1.85-2.2x) and `hungary & !slovakia` (1.04-1.12x).
  (Ranges here are per-host ratios of medians; `tables.md` has the pooled ratio and CI.)
- **pnorms** (pg_search against itself, per-host ratio of medians, no verdict computed)
  is 5-31% faster on rare, mid, common top-100, the 2-term OR, `slovakia & hungary`,
  `world & war` and NOT, and 29-49% faster on top-1000.  On common top-10, the 4-term OR,
  `united & states`, the phrases and the count it is within -6% to +7%.  It changes
  neither counts nor ids (gate and agreement above).  With it, pg_search leads pg_fts by
  2.1-2.3x on top-1000, 1.4-1.6x on the 4-term OR, 2.3-2.9x on `world & war` and
  1.10-1.19x on NOT.  pg_fts leads it by 4.2-4.6x on rare and 3.3-3.4x on common top-10.
- **VectorChord-bm25:** pg_fts is faster by 38-47x (rare), 66-88x (mid), 152-193x
  (common top-10), and 2.0-5.4x on the ORs.  Its top-1000 returned 100 rows (no claim).
- **GIN + ts_rank:** pg_fts is faster everywhere, by 28x (`slovakia & hungary`) to over
  10,000x (common top-10 on 19.0).  GIN's count of `year` is 400-578 ms on 18.7, and
  on 19.0 it is 535 ms on x86 but 2,015-2,041 ms on arm.  The 19.0 planner chose a
  Parallel Seq Scan there instead of the bitmap scan it used on 18.7 (`explain.txt`).
  That is the planner's choice, reported as measured.

### pg_fts on 19.0 vs 18.7

On the same host, pg_fts's 19.0/18.7 ratio of medians is 0.945-1.036 across all bands
and hosts.  The pass spreads overlap in 51 of 56 (band, host) cells, and the 5 that
separate are all 19.0 faster by 0.6-5.5%, never on both hosts of an architecture.
**No claim**: pg_fts performs the same on 19.0 as on 18.7.

## Settled throughput (tps, the two hosts of each architecture, median of 2 passes)

18.7, rare / common top-10 at 64 and 128 clients:

| | x86 c64 | x86 c128 | arm c64 | arm c128 |
|---|---|---|---|---|
| **pg_fts** rare | **119,720-122,464** | **128,407-135,713** | **144,415-148,213** | **141,495-143,671** |
| pg_textsearch main rare | 19,901-20,141 | 15,970-16,079 | 12,531-20,360 | 13,491-20,223 |
| pg_search rare | 46,980-47,150 | 10,225-18,378 | 48,769-48,802 | 36,206-36,387 |
| pg_search pnorms rare | 52,643-52,657 | 10,624-19,833 | 56,397-57,407 | 41,286-42,589 |
| VectorChord rare | 2,531-2,551 | 1,979-2,199 | 1,609-1,732 | 2,900-2,952 |
| GIN rare | 446-459 | 360-361 | 458-468 | 469-477 |
| **pg_fts** common | **120,709-120,878** | **164,299-164,361** | **138,196-147,683** | **118,471-125,838** |
| pg_textsearch main common | 1,342-1,403 | 1,281-1,294 | 3,483-3,564 | 3,516-3,597 |
| pg_search common | 44,409-44,960 | 21,333-29,222 | 48,416-48,795 | 36,151-36,316 |
| **pg_fts** count | **245,777-246,424** | **341,682-342,639** | **305,238-306,679** | **287,042-289,167** |
| pg_search count | 11,758-13,091 | 7,902-8,004 | 66,522-67,205 | 52,176-53,173 |

Every client count, the `united & states` band, and 19.0 are in `tables.md`.  pg_fts's
19.0 throughput is within a few percent of 18.7, and above it at 128-256 clients on x86
(common top-10 179-181k vs 164k; count 395-406k vs 342-354k).  The protocol's 1 s rule
skipped bands slower than 1 s single-client (pg_textsearch's filtered bands and count;
GIN's common bands).  pgbench recorded 0 failed transactions in every run.  GIN's count
at 256 clients aborted some clients with "too many dynamic shared memory segments" (its
parallel plan; 8 such runs), so its c256 count figure reflects fewer than 256 clients.
pg_search's rare top-10 on x86 drops at 128 clients and recovers at 256 in both passes on
both hosts (9.4-26.1k vs 37.4-44.7k per pass); that was measured, not explained.

## Cold first query (ms, median of 5, the two hosts)

| 18.7 | x86 | arm |
|---|---|---|
| **pg_fts** rare / common / `slovakia & hungary` | 41-46 / 47-55 / 55-62 | 41 / 47-48 / 54-55 |
| pg_textsearch main rare / common / and (cte) | **14-24 / 27-40** / 6,113-7,032 | **21-22 / 37-38** / 5,208-5,219 |
| pg_search rare / common / and | 35-67 / 36-70 / 36-67 | 36 / 44-50 / 46-50 |
| VectorChord rare / common | 987-2,353 / 1,235-1,239 | 2,023-2,045 / 915-1,066 |
| GIN rare / common / and | 1,990-2,118 / 7,218-8,380 / 947-1,445 | 1,638-1,780 / 6,787-6,866 / 1,209-1,232 |

pg_textsearch remains faster cold on single terms, as in 2026-10-15.  pg_fts's first
query in a backend builds per-backend directories.  The 19.0 cold numbers are similar
(`tables.md`).

## Build and size (2,188,038 rows)

| | build (x86 / arm) | index |
|---|---|---|
| **pg_fts** expression index | 255-264 s / 239-242 s | **1,369 MiB** |
| pg_fts `positions = on` (phrases) | 313-321 s / 283-285 s | 2,578 MiB |
| pg_textsearch (both) | 298-312 s / 265-269 s | 1,887 MiB |
| pg_search | **118-130 s / 123-124 s** | 2,308 MiB |
| pg_search pnorms | 134 s / 112-128 s | 2,704 MiB |
| VectorChord | model 891-894 s + tokenize 2,334-2,335 s + index 150 s / 812-813 + 2,208-2,228 + 161-162 s | 42,435 MiB |
| GIN | column 984-1,036 s + index 70-71 s / 782-792 + 73-76 s | 1,569 MiB, plus 6,349 MiB of heap for the stored column |

`fts_vacuum` after the build took 0.04-0.05 s and did not change the size.

## What changed since 2026-10-15

- pg_fts 1.13.0 -> 1.18.0:
  - rare top-10 on x86 went from 0.32-0.50 to 0.23 ms; common top-10 went from
    0.77-0.80 to 0.36 ms (arm unchanged at 0.23-0.24 and 0.33-0.35);
  - `"united states"` went from 3.37 to 2.56 ms on x86;
  - settled rare top-10 at 64 clients went from 143.6k to 119.7-122.5k on x86 and from
    148.4-149.7k to 144.4-148.2k on arm.  The x86 drop is not explained by anything in
    this run; that run used Fedora 44 and PG 17.10, and no single-variable comparison
    was made.
- pg_search 0.26.1 -> 0.27.0 (first time on metal): 1.9-2.2x faster than 1.11.0's
  virtualised r7gd.4xlarge numbers on single terms, the 2-term OR, `slovakia & hungary`
  and `world & war`, 1.2-1.5x on `united & states`, the 4-term OR and the phrases, and
  9.0-9.6x on the count.  Different hardware, OS and PostgreSQL, so not a single-variable
  comparison; for pg_search the 1.11.0 table is superseded by this one.

## Caveats

- **Hosts and binaries.**  Two hosts per architecture, the same AZ and the same AMI.
  Engines were installed from their release artifacts (pg_search's RPM, VectorChord's
  zips), so their compiler and flags are the vendors', not ours.
- **pg_textsearch main is a development snapshot** (8923a5ba, 2026-11-18), the only
  pg_textsearch that builds on 19.0.
- **VectorChord** used its tokenizer's documented English setup, as in 1.11.0.  Its
  42 GB index suggests the setup does not suit this corpus, so its numbers are reported
  but not used to characterize it.
- **No relevance judgements.**  This run says nothing about quality.  It has no write
  band, no replica or network storage, and no huge-page or NUMA tuning.
- **Gate 4 did not run** (see Correctness).
