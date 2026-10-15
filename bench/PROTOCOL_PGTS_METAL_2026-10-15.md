# pg_fts vs pg_textsearch on EC2 metal, Fedora, XFS on local NVMe (2026-10-15)

Written BEFORE the run, so the method cannot be fitted to the results.  It inherits every
rule of `PROTOCOL_110_2026-10-07.md`, `PROTOCOL_A_2026-10-07.md` and
`PROTOCOL_111_2026-10-09.md` except where a change is listed here.

## Why this run

The cross-engine numbers in README and BENCHMARK_SUMMARY are from 1.11.0, run on
virtualised r7gd.4xlarge hosts under Debian (`RESULTS_111_2026-10-09.md`).  Since then:

- pg_fts gained the I7 dictionary directory (1.12.0) and PR #12's compound proximity and
  positional AND/NOT (1.13.0).
- pg_textsearch's `main` moved past v1.5.1.

This run is a head-to-head on bare metal, so that no hypervisor sits between the engines
and the CPU or NVMe.  It covers more dimensions than the 1.11.0 run did, and it is
designed to be defensible to a pg_textsearch maintainer.

## Questions

1. **Single-client latency.**  On the bands both engines can express through their
   index, which engine is faster, by how much, and does the ordering reproduce on a
   second host of the same type?
2. **Throughput.**  How does each engine scale from 1 to 2x the core count in clients?
   The run uses settled throughput.
3. **Build and size.**  How long does each build take with its default parallelism,
   and how large is each index?
4. **Cold cache.**  How fast is a first query after the OS page cache is dropped?
5. **Concurrent writes.**  What are the query and insert throughput while inserts run,
   and are the results still correct afterwards?
6. **Architecture.**  Do the answers to 1 to 5 change between x86_64 and aarch64 metal?
7. **Correctness.**  Do the two engines return the same top-k for the same query?  If
   not, why not?  BM25 parameters, tokenizer and IDF definition are the expected
   reasons, and the run quantifies them rather than asserting them.

## Arms

| arm | build | identity recorded |
|---|---|---|
| pg_fts | **1.13.0 release**, from the PGXN zip | zip sha256 `47e24fd4...be55`, verified on the host before building |
| pg_textsearch | **`~/src/pg_textsearch` HEAD**, the tree the request names | `git describe` = `v1.5.0-4-ga5fdfeb1`, commit `a5fdfeb1`, 2026-10-01, `default_version 1.6.0-dev` |
| pg_textsearch (release) | **v1.5.1** tag, the latest release, as a third arm | tag commit `fa142d04` |

The pg_textsearch tree is shipped to the host as a tarball of that exact commit
(`git archive a5fdfeb1`), not cloned on the host, so the measured commit is the one named.
`v1.5.1` is not an ancestor of `a5fdfeb1`: the release came from a branch.  Both are
measured, so a reader can tell the release apart from development HEAD.

## Rig

- **x86_64 metal: c6id.metal.**  Intel Ice Lake, 128 vCPU, 256 GiB, 4x 1.9 TB local
  NVMe, 3.5 GHz sustained (describe-instance-types, 2026-10-15).  The fallback is
  m6id.metal (same CPU, 512 GiB) if capacity is unavailable; the type used is recorded.
- **aarch64 metal: c7gd.metal.**  Graviton3, 64 vCPU, 128 GiB, 2x 1.9 TB local NVMe,
  2.6 GHz.  The fallback is m7gd.metal (256 GiB).
- **Two hosts per architecture, one engine-pair per host.**  Both engines run on BOTH
  hosts, so every engine is measured twice per architecture on different physical
  machines.  Within a host the engines alternate by band and pass, never all of one
  engine first.  This follows from the 2026-10-09 finding that EC2 host state moves
  absolute throughput by up to 35% between hosts of the same type
  (`RESULTS_TPS_VARIANCE_2026-10-09.md`).  Because every comparison is made within one
  host, host-to-host variance cancels.  The second host is the reproduction rule (rule 4).
- **Host state.**  Recorded before and after each run:
  - the `mbench2` 1 GiB 4 KiB-page pointer chase (`RESULTS_TPS_VARIANCE`);
  - `lscpu`, `numactl -H` and `uname -r`;
  - THP mode, CPU governor where exposed, and the NVMe model.
- **OS: Fedora Cloud Base 44** (official AMI, owner 125523088429),
  `Fedora-Cloud-Base-AmazonEC2.{x86_64,aarch64}-44-20261014.0`, the same build date on
  both architectures (checked 2026-10-15).  The AMI name is recorded; its ID is not
  committed.  User `fedora`; packages via `dnf`.
- **Storage.**  XFS (`mkfs.xfs` defaults), mounted `noatime`, on ONE local NVMe
  instance-store device, holding the data directory, WAL, corpus and builds.  The other
  NVMe devices are left unused, so that RAID striping is not in play.
- **PostgreSQL 17.10** from source, `-O2 -g -fno-omit-frame-pointer`, identical on every
  host.  Both engines support 17 and 18; 17 matches the prior runs.  Settings:
  - `shared_buffers = 32GB`, `work_mem = 256MB`, `maintenance_work_mem = 8GB`;
  - `max_parallel_maintenance_workers = 8`, `max_worker_processes = 32`;
  - `jit = off`, `max_connections = 300`;
  - `autovacuum = off` during measurement;
  - `shared_preload_libraries = 'pg_prewarm,pg_textsearch'` on every host, so both
    engines run under the same preload set.  pg_textsearch requires the preload;
    pg_fts ignores it.
  - `pg_prewarm.autoprewarm = off`.
- **NUMA.**  The metal hosts have 2 sockets (c6id.metal) or 1 (c7gd.metal).  PostgreSQL
  runs untuned, as shipped; `numactl -H` is recorded.  NUMA pinning is not part of this
  comparison, and both engines face the same topology.

## Corpus

The same 2,188,038-article English Wikipedia corpus (`wikimedia/wikipedia`
`20231101.en`, `content = title || ' ' || body`), built by the embedded `corpus.py`.  The
TSV md5 must equal `f5939e85...` on every host, or the run stops.  Each engine indexes
`content` with English stemming using its documented setup:

- pg_fts: `CREATE INDEX ... USING fts (to_ftsdoc('english', content))`, an expression
  index, as both engines analyse text inside the build.  A second, `positions = on`
  index serves the phrase bands, and its build and size are reported separately.
- pg_textsearch: `CREATE INDEX ... USING bm25 (content) WITH (text_config = 'english')`.

## Bands (ranked top-k unless stated)

| band | query | notes |
|---|---|---|
| rare k10 | `slovakia` | df ~10.9k |
| mid k10 | `hungary` | df ~24.1k |
| common k10, k100, k1000 | `year` | df ~735k; k1000 is new (deep page) |
| 2-term OR k10 | `slovakia \| hungary` | pg_textsearch: its native multi-term `<@>` query is a disjunction scored by BM25, the like-for-like form |
| 4-term OR k10 | `film \| music \| album \| band` | MaxScore regime |
| AND k10 | `slovakia & hungary`, `united & states` | pg_textsearch: `@@ to_tsquery` + `<@>`, its documented form |
| phrase k10 | `"united states"`, `"world war"` | pg_fts: positions index; pg_textsearch: `@@ 'united <-> states'` + `<@>` |
| NOT k10 | `hungary & !slovakia` | new; 1.13.0 changed this path |
| exact count | `count(*)` of `year` | pg_textsearch has no count path through its index: n/a |

pg_textsearch v1.5.0+ supports Boolean and phrase filters through `@@` on its index.  Its
README says that combining a filter with ranking "is not yet optimized as a single index
scan".  The planner's choice is recorded with EXPLAIN for every band on every engine.  A
band that runs as a sequential scan is timed with a 300 s statement timeout and reported
as the measured time or ">300 s (seq scan)".  It is never omitted and never replaced by
a different query.

## Timing

- **Latency.**  8 executions per query inside ONE psql session with `\timing`; the
  median of the last 5 is taken.  There are 3 passes per band per engine on each host,
  with engines alternating per pass, after prewarming heap and index.  Reported: the
  median of the 3 pass-medians, the pass spread, and the second host's value.  A
  between-engine difference is called only if the two engines' pass spreads do not
  overlap on BOTH hosts.
- **Throughput, settled form** (`tps2.sh`):
  - CHECKPOINT, sync, 60 s idle, prewarm, then a 10 s warm-up at 8 clients;
  - then C in {1, 16, 64, 128, 256} x 30 s x 2 passes, with `-j min(C, 64)`;
  - 128 is 1x the x86 core count and 2x the arm count.
  - Bands: rare k10, common k10, AND `united & states`, count (pg_fts only).
- **Cold cache.**  Stop PG, `sync; echo 3 > /proc/sys/vm/drop_caches`, start PG, run one
  query, and take the `EXPLAIN (ANALYZE, BUFFERS)` execution time.  5 repetitions,
  median.  Bands: rare k10, common k10, AND k10.
- **Build.**  Each index is built once per host, timed, with each engine's default
  parallel build (`max_parallel_maintenance_workers = 8`).  Size is
  `pg_relation_size` plus any auxiliary relations each engine creates, enumerated from
  `pg_class`.  pg_fts is also measured after `fts_vacuum`, and whether that changes the
  size is recorded.
- **Concurrent write band.**  8 pgbench clients insert single-row autocommit documents
  (an article prefix with a unique token) for 120 s, while 8 clients run rare k10.  The
  pg_fts arm also runs `fts_merge` every 30 s; pg_textsearch runs its own background
  compaction.  Reported: insert tps and query tps.  Afterwards, the index count of the
  unique-token term must equal the heap count, for each engine; for pg_textsearch this
  is checked by ranked retrieval with LIMIT >= the inserted count.
- No `/usr/bin/time` around psql, no single-run numbers, and no numbers from another
  day or host.

## Correctness gate (before any timing is believed)

1. The corpus md5 matches.
2. Every band returns k rows (or the full match set) on every engine.  A timeout is
   recorded as a timeout.
3. For the probe terms `slovakia`, `hungary` and `year`, each engine's match count is
   compared with a regex ground truth.  Tokenizer differences are reported in the
   results, not hidden.
4. pg_fts top-10s are checked against its exhaustive oracle (`mt_oracle.py`,
   `and_oracle.py`, as in prior runs); a band that fails is not timed.
5. **Cross-engine agreement, which is new.**  For each single-term and OR band,
   reported:
   - the overlap of the two engines' top-10 and top-100 id sets;
   - the Spearman rank correlation over the shared ids.

   Expected differences, read from both sources on 2026-10-15:
   - **k1 and b.**  The defaults are identical: k1 = 1.2 and b = 0.75 in both
     (pg_textsearch `src/constants.h` `TP_DEFAULT_K1/B`).
   - **IDF.**  The formula is identical, `ln(1 + (N - df + 0.5)/(df + 0.5))`
     (pg_textsearch `src/scoring/bm25.c`).  pg_textsearch computes it in `float4`;
     pg_fts uses double and clamps df to [1, N].
   - **Document length.**  Both quantize to one byte: pg_fts v4 in its sidecar
     (`fts_doclen_to_byte`), pg_textsearch as an encoded "fieldnorm" per document
     (`src/access/build_context.h`).  The encodings differ, and so do the lengths a
     score sees.
   - **N and df after deletes.**  Not exercised here, since the corpus has no deletes.
   - **Stemming and stopwords.**  Both use PostgreSQL's `english` configuration;
     pg_textsearch calls `to_tsvector`, and pg_fts calls the configured parser
     through `to_ftsdoc('english', ...)`.  To separate those from bugs, both
   engines' top-10 are rescored with pg_fts's `fts_bm25` using one fixed formula and the
   corpus statistics.  If both lists are optimal under their own engine's formula, a
   disagreement is a formula difference, not a ranking error.  This is a check of
   semantics, not a quality claim: there is no relevance judgement set for this corpus.

## What is NOT claimed

- Search quality, relevance or nDCG.  There are no judgements.
- Anything about pg_search, VectorChord, GIN or TIN.  They are not in this run, and the
  README keeps its 1.11.0 table for them, labelled as such.
- Network storage (gp3/io2), multi-node setups, or replicas.
- Tuned NUMA placement, huge pages beyond the OS default, or kernel tuning.
- Any number from a host that failed the md5 check or whose mbench2 chase moved by more
  than 15% during the run.  Such a run is repeated, not reported.
- Vendor or third-party figures.

## Cost and teardown

Four metal hosts:
- c6id.metal about $6.45/h and c7gd.metal about $2.9/h on demand, us-east-2;
- estimated 6-8 h wall time, so roughly $80-120 in total.

Hosts are launched with `owner=gburd-agent` tags in the kiwi account and terminated, with
their security groups and key pairs, as soon as their data is copied off.  Teardown is
checked with a describe call that returns 0.

## Amendments from the smoke test (before any metal run)

The harness was smoke-tested on one Fedora 44 c6id.2xlarge with 50,000 rows of the same
corpus, then destroyed.  The smoke results are not reported as measurements.  They
changed the method as follows:

1. **The positions index lives on its own copy of the table** (`docs_pos`), because the
   planner chose the `positions = on` index for non-phrase bands once both indexes
   were on one table.  That made rare k10 20.7 ms instead of 0.1 ms.  Phrase bands
   query `docs_pos`, and its size is reported separately.
2. **pg_textsearch's filtered ranked bands are also run in a second form,** a
   `MATERIALIZED` CTE that applies the `@@` filter through the bm25 index and then
   scores and sorts the matches.  In the documented single-query form
   (`WHERE content @@ ... ORDER BY <@> ... LIMIT`) the planner chooses a sequential scan
   even with `enable_seqscan = off`.  In the smoke test that took 30 s for
   `slovakia & hungary` at 50k rows, against 0.3 s for the CTE form.  Both forms are
   reported (`*_k10` and `*_k10_cte`); the faster one is pg_textsearch's number for the
   band, and that is stated.
3. **pg_fts common k1000 is measured as shipped.**  At 50k rows the planner chooses
   bitmap + Sort for LIMIT >= 250 on an expression index, and the query takes 21.6 s
   (4-7 ms on the ordering scan).  This is a pg_fts planner-costing defect, ROADMAP
   I11, present in every release.  It is reported as measured, with the
   `enable_bitmapscan = off` time alongside as a labelled diagnostic, not as pg_fts's
   number.
4. **Write band inserts use a sequence** (a `random()`-based id overflowed `int` in
   pgbench), and each arm starts with the previous arm's write-band rows deleted.
5. **Latency timing takes the first 8 `Time:` lines** after `\timing on`; an earlier
   filter dropped sub-millisecond values.
6. **Repetitions are bounded for bands slower than 10 s** (added during the metal run,
   before any between-engine comparison was read).  Each band now runs once as a probe.
   A probe over 10 s is followed by 3 timed executions, and the median of those 3 is
   reported, instead of 8 executions and the median of the last 5.  The trigger was
   pg_textsearch's `and_us_k10_cte`: each execution took minutes but finished just under
   the 300 s statement timeout, so 8 per pass, times 3 passes and 3 arms, would have
   taken many hours per host.  Rows record `reps=` and the probe time.  The 300 s
   statement timeout is unchanged.
7. **A band slower than 60 s is recorded from its probe alone**: one execution per pass,
   so three across the passes.  Added after latency pass 1, before any comparison was
   read.  Pass 1 took 2.5 h per host, almost all of it pg_textsearch's filtered bands at
   4-5 minutes per execution.  Throughput skips any band whose pass-1 latency exceeds
   1 s (pgbench would report under 1 tps), and says so in `tps.txt`.
