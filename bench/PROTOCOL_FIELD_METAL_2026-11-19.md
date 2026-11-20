# pg_fts 1.18.0 vs the field on EC2 metal, Fedora 45, XFS, PostgreSQL 18.7 and 19.0 (2026-11-19)

Written BEFORE any host was launched, so the method cannot be fitted to the results.  It
inherits every rule of `PROTOCOL_PGTS_METAL_2026-10-15.md` (metal, Fedora, XFS, both
architectures, two hosts per architecture, alternation, bounded slow bands) and the
engine set of `PROTOCOL_111_2026-10-09.md`, except where this file says otherwise.
Amendments made after the smoke test or during the run go at the end, each before any
between-engine comparison is read.

## Why this run

- The cross-engine table in README and `BENCHMARK_SUMMARY.md` is still the 1.11.0 run
  (`RESULTS_111_2026-10-09.md`): virtualised r7gd.4xlarge, Debian, PG 17.10, one host
  per engine.  The 2026-10-15 metal run compared pg_textsearch only.
- pg_fts has had seven releases since 1.11.0.  1.18.0 vendors sparsemap 5.9.0, which made
  ranked queries on tombstoned indexes 17-31% faster.  This run's indexes have no
  tombstones, so it does not repeat that measurement.
- PostgreSQL 19.0 was released today (2026-11-19).  pg_fts 1.18.0 supports it.

## Questions

1. **Single-client latency per band, every engine, on bare metal.**
2. **Settled throughput, 1 to 2x the core count.**
3. **Build time and index size.**
4. **Cold cache.**
5. **Architecture.**  Do 1 to 4 change between x86_64 and aarch64 metal?
6. **PostgreSQL 19.0.**  How do the engines that run on 19.0 compare there?  Does pg_fts
   change between 18.7 and 19.0, measured on the same host?
7. **Correctness and agreement.**  Correct counts against a regex ground truth,
   pg_fts's results against its exhaustive references, and cross-engine top-k
   agreement with a common-formula rescore.

## Engines and versions

| arm | version | form | PG 18.7 | PG 19.0 |
|---|---|---|---|---|
| **pg_fts** | **1.18.0**, the PGXN zip (sha256 `567dde01...`, checked on the host) | source build | yes | yes |
| pg_textsearch | **v1.5.1** (latest release, 2026-10-02) | `git archive` of the tag | yes | **no**: does not compile on 19.0 (`INT_MAX` undeclared, `src/planner/hooks.c:1963`; checked 2026-11-19) |
| pg_textsearch | **main `8923a5ba`** (2026-11-19, `1.6.0-dev`; PG 19 required in its CI since 2026-11-18) | `git archive` of that commit | yes | yes |
| pg_search | **0.27.0** (released 2026-11-19), default index | official `el10` RPM for PG 18 (`.so` and SQL extracted, as the earlier runs extracted the `.deb`) | yes | **no**: 0.27.0 has no `pg19` cargo feature and no PG 19 package |
| pg_search, `pnorms` | the same 0.27.0 binary, index built with `pnorms=true` | as above | yes | no |
| VectorChord-bm25 | **0.3.0** with pg_tokenizer **0.1.1** (latest releases) | official `linux-gnu` zips for PG 18 | yes | **no**: no PG 19 package, and no `pg19` feature in either crate |
| GIN | built in | PostgreSQL's documented form (12.2.2): a stored generated `tsvector` column with a GIN index on it, ranked with `ts_rank` | yes | yes |

Each version's identity is recorded on the host: the zip sha256, the git commit, the
RPM/zip sha256, and the `.so` md5.  GIN is the built-in baseline.  It cannot do ranked
top-k from the index: `ORDER BY ts_rank(...)` reads every match from the heap.  It is
reported for what it is, and its exact `count(*)` (bitmap) is the most direct built-in
comparison for pg_fts's index count.

pg_search's index: `CREATE INDEX ... USING paradedb (id, (content::pdb.simple('stemmer=english')))`,
the 0.27.0 documented form: `paradedb` is the access method name, `bm25` its alias, and
there is no `key_field`, which 0.27.0 deprecates and ignores.  pg_search 0.26.0 added a
documented option for exactly this workload: `pnorms=true` "can make [top K] queries
several times faster without changing scores", at the cost of a larger index and a longer
build (docs `reference/indexing/faster-bm25-queries`).  It defaults to off, so pg_search
runs in two arms on its own table copies:

- **as shipped**, with the default index;
- **`pnorms`**, with `content::pdb.simple('stemmer=english', 'pnorms=true')`.

A maintainer would ask for the second, and a user who has not read that page gets the
first.  Otherwise its settings are left as shipped: no tuning of segments, memory or
parallelism beyond the cluster settings below, the same as for every engine.  pg_fts runs
with its defaults.

## Rig

- **x86_64 metal: 2x c6id.metal** (Intel Xeon 8375C, 2 sockets, 128 vCPU, 256 GiB).
- **aarch64 metal: 2x c7gd.metal** (Graviton3, 1 socket, 64 vCPU, 128 GiB).
- **OS: Fedora Cloud Base 45** (official AMIs, owner 125523088429,
  `Fedora-Cloud-Base-AmazonEC2.{x86_64,aarch64}-45-20261119.0`, both built today).  The
  AMI name is recorded; its ID is not committed.
- **Storage: XFS** (`mkfs.xfs` defaults, `noatime`) on ONE local NVMe instance-store
  device.  It holds the data directories, WAL, corpus and builds; no RAID.
- **PostgreSQL 18.7 and 19.0** from the release tarballs, `-O2 -g -fno-omit-frame-pointer`,
  no asserts, identical flags on every host.
  - Each arm has its own copy of the prefix: the `postgres` binary md5 must be identical
    across the arms of one major.
  - Each arm has its own data directory and its own copy of the table.
- **Settings**, identical for every cluster:
  - `shared_buffers = 32GB`, `work_mem = 256MB`, `maintenance_work_mem = 8GB`;
  - `max_parallel_maintenance_workers = 8`, `max_parallel_workers = 32`,
    `max_worker_processes = 32`;
  - `jit = off`, `max_connections = 300`, `autovacuum = off` during measurement;
  - `default_text_search_config = 'english'`;
  - `shared_preload_libraries = 'pg_prewarm'`, plus what an arm requires: pg_textsearch
    and pg_search add their own libraries.
  - Exactly one cluster runs at a time.
- **Preflight** (`pg-benchmark-rigor`), recorded before and after each phase:
  - CPU model, microcode, `uname -r`, `lscpu`, `numactl -H`;
  - THP set to `never` for `enabled` and `defrag`;
  - governor `performance` where exposed;
  - Intel turbo off (`intel_pstate/no_turbo = 1`); Graviton has no boost;
  - load average;
  - the `mbench2` 1 GiB pointer chase, whose drift must stay under 15% or the host's run
    is repeated;
  - `perf stat -e cycles true`, to show hardware counters exist.

  Not controlled: SMT, C-states and ASLR.  These are left as shipped and listed as
  uncontrolled items in the results.  No pinning: the scheduler is part of what users
  get.
- **Cost.**  c6id.metal about $6.45/h and c7gd.metal about $2.9/h, so about $19/h for
  four hosts.  The estimate is 12-16 h, about $230-300.  Hosts are in the `compass`
  account, tagged `owner=gburd-agent`, and terminated with their security groups and
  keys as soon as their data is copied off; a describe call returning 0 checks it.

## Corpus

The same 2,188,038 English Wikipedia articles (`wikimedia/wikipedia` `20231101.en`,
`content = title || ' ' || body`), built by the embedded `corpus.py`.  The TSV md5 must
be `f5939e85...` on every host or the run stops.  Every engine indexes `content`, and
nothing else, with English stemming in its documented setup.

## Bands (ranked top-k unless stated)

| band | pg_fts | notes |
|---|---|---|
| rare k10 | `slovakia` | df ~10.9k |
| mid k10 | `hungary` | df ~24.1k |
| common k10 / k100 / k1000 | `year` | df ~735k |
| OR2 k10 | `slovakia \| hungary` | |
| OR4 k10 | `film \| music \| album \| band` | |
| AND k10 | `slovakia & hungary`, `united & states`, `world & war` | |
| NOT k10 | `hungary & !slovakia` | |
| phrase k10 | `"united states"`, `"world war"` | pg_fts: `positions = on` index on its own table copy |
| exact count | `count(*)` of `year` | engines without an index count path: n/a |

Each engine runs each band in its own documented form:

- **pg_textsearch:** `<@>` with `to_bm25query`, and `@@ to_tsquery` filters.
  Filtered bands also run in the `MATERIALIZED` CTE form (amendment 2 of 2026-10-15),
  and the faster of the two is its number.
- **pg_search:** `|||`, `&&&` and `###` with `pdb.score(id)`.  NOT is
  `content &&& 'hungary' AND NOT content &&& 'slovakia'`; it is used only if EXPLAIN
  shows one index scan, and otherwise reported as n/a.
- **VectorChord:** `<&>` with `to_bm25query`.  It has no boolean filter, so AND, NOT
  and phrase are n/a.
- **GIN:** `tsv @@ to_tsquery('english', ...)` ordered by `ts_rank(tsv, q) DESC`, on
  the stored column.  The count is `count(*) ... tsv @@ to_tsquery`.  Its build is
  reported as the column fill plus the index, with the heap growth from the column.

The planner's choice is recorded with EXPLAIN for every band on every arm.  A band that
runs as a sequential scan is timed with a 300 s statement timeout and reported as the
measured time or ">300 s".  It is never dropped or replaced by another query.  Slow
bands keep the 2026-10-15 bounds:

- over 10 s: median of 3 executions;
- over 60 s: one execution per pass;
- a timeout is not retried in later passes.

## Timing and statistics

- **Latency.**  Each pass runs 8 executions in ONE psql session with `\timing`, and
  takes the median of the last 5.
  - **5 passes** per band per arm per host (3 before).  The arm order is rotated each
    pass, after prewarming heap and indexes.
  - **A/A:** pg_fts runs twice in every pass, as arms `fts` and `fts_aa`: the same
    cluster and index, at different positions in the order.  The A/A spread is the noise
    floor for each band on each host.
  - Reported:
    - the median of the 5 pass-medians, with the pass min-max;
    - the second host's value;
    - for pg_fts against each engine, the ratio of medians with a bootstrap 95% CI
      (10,000 resamples of the pass-medians of both hosts).
  - **Verdict per comparison** (`pg-benchmark-rigor` section 6):
    - `STABLE` if the two arms' pass spreads separate on both hosts of an architecture
      and the effect exceeds 3x the A/A spread;
    - `NOISY` if they separate on one host only;
    - `NO CLAIM` otherwise.
- **Throughput** (settled, `tps2.sh`-form):
  - per arm: CHECKPOINT, sync, 60 s idle, prewarm, a 10 s warm-up at 8 clients;
  - then C in {1, 16, 64, 128, 256} for 30 s each, with `-j min(C, 64)`;
  - 2 passes per arm, with the arm order reversed in pass 2;
  - bands: rare k10, common k10, AND `united & states`, count;
  - a band whose pass-1 latency exceeds 1 s is skipped and stated;
  - every pgbench output is checked for `aborted` and failed transactions before any
    number is read.
- **Cold cache.**  Stop PG, `sync; echo 3 > /proc/sys/vm/drop_caches`, start PG, run one
  query under `EXPLAIN (ANALYZE, BUFFERS)`.  5 repetitions, median.  Bands: rare k10,
  common k10, AND k10.
- **Build.**  Once per arm per host, with each engine's default parallel build, timed:
  - the total, and its steps for VectorChord (model, tokenize, index);
  - size = `pg_relation_size` of every relation the engine adds (from `pg_class`),
    excluding the heap, its TOAST and its primary key;
  - pg_fts also after `fts_vacuum`.
- **PG 19.0 phase.**  The same latency, throughput and build phases, for pg_fts,
  pg_textsearch main and GIN, after the 18.7 phase on the same host.  The 18.7 to 19.0
  comparison for pg_fts and pg_textsearch main is made on one host, by the same verdict
  rule.
- No `/usr/bin/time` around psql.  No single-run numbers.  No numbers from another day,
  host or OS.  No vendor figures.

## Correctness gate (before any timing is believed)

1. The corpus md5 matches.
2. Every band returns k rows, or the full match set, on every arm.  A timeout is
   recorded as a timeout.
3. Match counts for `slovakia`, `hungary` and `year` are compared with the regex ground
   truth on every engine that can count.  Tokenizer differences are reported, not
   hidden.
4. pg_fts's top-k for the OR, AND and phrase bands is checked against its exhaustive
   references (`mt_oracle_idx.py`, `and_oracle_idx.py`).  A band that differs is not
   timed.
5. **Agreement.**  For the single-term and OR bands:
   - the top-10 and top-100 id overlap of every engine with pg_fts;
   - each engine's top-100 rescored with ONE formula (`fts_bm25`: Lucene IDF, k1 1.2,
     b 0.75, exact document lengths, the corpus N and avgdl).

   This checks semantics, not quality.  There are no relevance judgements.
6. On 19.0, pg_fts's and pg_textsearch main's top-k ids must equal their 18.7 ids on
   the same host.

## What is NOT claimed

- Relevance quality.  There are no judgements.
- PG 19.0 numbers for pg_search and VectorChord, which do not ship for it.
- Network storage, replicas, multi-node.
- Tuned NUMA placement, huge pages beyond the OS default, kernel tuning beyond the
  preflight.
- TIN or any managed-only engine (rule 10).
- Write throughput: no concurrent-write band in this run.  It was a correctness band
  for pg_fts's own write paths, and 1.18.0's gate covered those.

## Smoke test

Before any metal host, the whole harness runs once on a Fedora 45 c6id.2xlarge at
50,000 rows, for every arm and both majors, then the host is destroyed.  Its numbers are
not reported.  Any method change it forces is written below as an amendment before the
metal run.

## Amendments

All of these were made after the smoke test (c6id.2xlarge, Fedora 45, 50,000 rows) and before
any measured run.

1. **pg_search needs pgvector.** The 0.27.0 control file has `requires = 'vector'`.  pgvector
   v0.8.7 (the latest tag, f37c13f6) is built from source into the pg_search prefixes, and the
   extension is created with `CASCADE`.  On Fedora 45, the RPM's `libopenblas.so.0` comes from
   `openblas-serial`, not `openblas`.
2. **GIN uses a stored column.** The smoke's expression-index GIN re-parsed the text of every
   match inside `ts_rank` (504 ms for the rare top-10 at 50k rows).  PostgreSQL documents the
   stored `tsvector` column for ranked search, and that is what a user would deploy.  The
   build reports the column fill, the index build, and the heap growth separately.
3. **One harness per host.** A second smoke run raced the first on one host.  setup_arms now
   stops any server left holding the socket, and an arm's cluster counts as ready only after
   its setup completes (`.field_ready`).
4. **Fedora launch helpers.** EC2 user `fedora`, root device `/dev/sda1`.  These change only the
   launch helpers.
5. **The VectorChord index is 5.0 GB at 50,000 rows**, against pg_fts's 82 MB.  The earlier
   2.19M-row runs measured 41 GB with the same documented setup.  It gets reported as
   measured, with the 1.11.0 caveat that this setup does not seem to suit this corpus.
