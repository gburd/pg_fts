# Feature comparison matrix — pg_fts vs PostgreSQL BM25 alternatives

Scope: **PostgreSQL-embedded BM25 full-text search extensions**, plus built-in
`tsvector`/GIN as the baseline everyone already has. Compiled 2026-09-09 against
pg_fts **v1.6.0**.

Competitor rows reflect **what we exercised in our own benchmark runs** (see
`bench/BENCHMARK_SUMMARY.md` and `bench/data_5way_159b/`), not vendor claims. Where
a capability was not exercised, it is marked *untested* rather than guessed.

Versions measured: pg_textsearch `f940210`; pg_search (ParadeDB) 0.25.6 /
paradedb `c807ede`; VectorChord-bm25 `14fc2a3`.

Legend: **Yes** = exercised and working · **No** = absent · *n/t* = not tested by us

---

## Query capability

| Capability | pg_fts | pg_textsearch | pg_search | vchord | tsvector/GIN |
|---|---|---|---|---|---|
| BM25 ranked top-k | **Yes** | Yes | Yes | Yes | No (ts_rank is not BM25) |
| Boolean match predicate (AND/OR/NOT) | **Yes** | No | Yes | **No** (ranking only) | Yes |
| Exact `count(*)` of a match set | **Yes** (index-native) | **No** | Yes | **No** | Yes (heap/bitmap) |
| Phrase queries | **Yes** | No | Yes (`###`) | No | Yes (`<->`) |
| NEAR / proximity with distance | **Yes** | No | *n/t* | No | Yes (`<N>`) |
| Prefix terms (`term*`) | **Yes** | No | Yes | No | Yes |
| Fuzzy terms (Levenshtein) | **Yes** (`term~k`, DFA) | No | *n/t* | No | No |
| Regex terms | **Yes** (`/re/`) | No | *n/t* | No | No |
| BM25 variants (lucene/robertson/atire/bm25+/bm25l) | **Yes** | No | No | No | n/a |
| BM25F multi-field weighting | **Yes** | No | *n/t* | No | No |
| Field zones / weighted sections | **Yes** (`term:A`) | No | *n/t* | No | Yes (setweight) |
| Highlight / snippet | **Yes** | No | *n/t* | No | Yes (ts_headline) |
| Index-maintained corpus stats (N, avgdl, df) | **Yes** | No public API | *n/t* | No | No |
| Lexical anomaly detection | **Yes** | No | No | No | No |
| `tsquery` migration path | **Yes** (cast + helper) | n/a | No | No | n/a |

**Read:** query-language breadth is pg_fts's widest margin. pg_textsearch is ranked
retrieval only; vchord is ranking-only by design (no boolean or count support at
all); pg_search is the only competitor with comparable breadth.

## Correctness and semantics

| Property | pg_fts | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| Uses PostgreSQL `english` text-search config | **Yes** | Yes | **No** (Tantivy) | Yes |
| English stemming applied | **Yes** | Yes | **No** | Yes |
| Match counts agree with the other stemming engines | **Yes** (byte-identical) | Yes | **No** (−33% on `year`) | Yes |
| Exact top-k (verified against a heap sort) | **Yes** (`parity_check.sh`, 10 cases) | *n/t* | *n/t* | *n/t* |
| Unverifiable phrase behaviour | **false** (matches PG `OP_PHRASE`) | n/a | *n/t* | n/a |
| MVCC-correct deletes | **Yes** (tombstones) | *n/t* | *n/t* | *n/t* |
| WAL-logged / crash-safe | **Yes** (all writes via GenericXLog) | *n/t* | *n/t* | *n/t* |
| Physical-replication safe (failover tested) | **Yes** (`t/002`) | *n/t* | *n/t* | *n/t* |

**Read:** the stemming row is the important one. pg_search's speed advantage is
partly a different (smaller) unit of work — it does not stem, so `year` matches
495,580 documents where the correct English answer is 734,896, confirmed by regex
on the raw text.

## Performance (2.19M Wikipedia articles, identical single column)

| Measure | pg_fts | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| **Index size** | **1,421 MB** | 1,887 MB | 2,734 MB | 2,902 MB |
| Build time | 381 s | 496 s | **127 s** | **56 s** |
| rare k10 | **5.89 ms** | 7.36 | 2.13 | 2.48 |
| mid k10 | 10.64 | **7.96** | 2.04 | 2.40 |
| common k10 | 36.16 | 20.71 | **2.12** | 3.49 |
| common k100 | 46.01 | 50.71 | **3.72** | 24.52 |
| exact `count(*)` | **2.20 ms** | — | 13.63 | — |
| phrase (tuned) | 229 ms | — | **22.9** | — |

**Read:** pg_fts wins size and `count(*)`, is competitive on rare/mid against the
like-for-like comparator, and clearly trails on common-term ranked and phrase.

## Operational surface

| Property | pg_fts | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| Requires `shared_preload_libraries` | **No** (verified: every benchmark/test cluster ran without it, and the `FtsCount` CustomScan pushdown still fires) | **Yes** | **Yes** | **Yes** |
| Pure C (no Rust toolchain to build) | **Yes** | Yes | No (Rust/pgrx) | No (Rust/pgrx) |
| Extra build dependencies | none | none | openblas, pgvector, pgrx | pgrx |
| Incremental maintenance (no REINDEX to add rows) | **Yes** (pending list) | *n/t* | *n/t* | *n/t* |
| `CREATE INDEX CONCURRENTLY` | **Yes** (verified) | *n/t* | *n/t* | *n/t* |
| Parallel index build | **Yes** (faster; no durable size cost) | *n/t* | *n/t* | *n/t* |
| Parallel scan | No (built, measured, reverted) | *n/t* | *n/t* | *n/t* |
| Managed-service safe (replica guard, privileges) | **Yes** | *n/t* | *n/t* | *n/t* |
| Non-UTF-8 server encodings | **Yes** (fixed 1.5.9) | *n/t* | *n/t* | *n/t* |
| Big-endian hosts | **Untested** (no CI) | *n/t* | *n/t* | *n/t* |

> **Note on parallel builds (corrected 2026-09-09):** an earlier sweep reported a
> parallel build as ~17% larger than serial. That was measured **before**
> `fts_vacuum`. Re-measured with the vacuum step, serial and 4-worker builds land at
> **identical size** (1,420 MB each) with identical match counts — a parallel build is
> faster and leaves more *reclaimable residue*, not a bigger index. Run `fts_vacuum`
> once after a large build. Details in `bench/BENCHMARK_SUMMARY.md`.

**Read:** not needing `shared_preload_libraries` is a genuine deployment
advantage — the other three all require a restart to install, and on a managed
service may require provider support. Being pure C also matters: two competitors
need a Rust toolchain, and pg_search additionally needs OpenBLAS and pgvector.

---

## Choosing between them

- **pg_fts** — you want one index that answers ranked BM25 *and* boolean, exact
  counts, phrase, prefix, fuzzy and regex, with PostgreSQL-consistent stemming, the
  smallest on-disk footprint, and no preload/Rust requirement. Accept slower
  common-term ranked queries.
- **pg_search** — you want the fastest ranked latency across the board and can
  accept a Tantivy analyzer that does not stem (so results differ from
  `to_tsvector`), a 1.9× larger index, and a Rust build.
- **vchord** — you want fast ranking and nothing else; it has no boolean or count
  support, and the largest index here.
- **pg_textsearch** — you want a minimal, familiar BM25 ranking on top of
  PostgreSQL's own analyzer, and need nothing beyond ranked retrieval.
- **tsvector/GIN** — already in PostgreSQL, mature tooling, but no BM25 and no
  index-native top-k.

### What this matrix does NOT cover

Three dimensions normally used to judge a BM25 access method are **absent**, and their
absence is not evidence of parity (`bench/COVERAGE_AUDIT_2026-09-10.md`):

- **Concurrent throughput (QPS) — now measured for pg_fts.** Every *latency* figure in
  this document is single-client, but the scaling question is answered
  (`bench/RESULTS_C1_UNDERLOAD_2026-09-11.md`): **pg_fts scales 10.7x from 1 to 32
  clients** on rare-term ranked (9.9x on common), with throughput still rising at 32
  and latency flat from 1 to 8. That is the healthy shape — vchord by contrast
  *collapses* (2.6x, then 1,322 -> 1,161 tps from 8 to 32 clients). `count(*)` holds
  **2,922 tps at 32 clients** on a 735k-match term against pg_search's 54 tps.
  What is still missing is a **like-for-like cross-engine re-run on current versions
  with one documented query form**: the existing cross-engine table is from Aug 27 and
  its harness is lost, so absolute tps should not be compared across the two runs.
- **Ingest / update throughput.** We measure bulk build only. Sustained INSERT rows/s,
  DELETE/UPDATE cost, and how latency degrades as the pending list grows between
  merges are unmeasured for every engine.
- **Ranking quality (NDCG / recall vs a reference).** We verify our own exactness
  (top-k parity against an exact sort, gated per release) but have never compared
  *relevance ordering* against a rival. This matters here because pg_search does not
  stem, so it answers a different query.

### Caveats on this matrix
Every *n/t* is a real gap in our knowledge, not an implied "No". We benchmarked the
competitors for latency, size and match counts on one corpus; we did **not** audit
their crash safety, replication behaviour, MVCC correctness or concurrency, all of
which pg_fts has been tested for at length (and had bugs found in). A fair reading
is that our own rows are better evidenced than the competitors' — including the rows
where we lose.
