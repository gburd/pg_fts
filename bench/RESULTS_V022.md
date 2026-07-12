# pg_fts v0.2.2 — competitive benchmark and v0.2.0-vs-v0.2.2 before/after

Fresh measurement of the **current release (v0.2.2, HEAD `5041c11`)** against
the last benchmarked pg_fts version (**v0.2.0**, the P1-P4 baseline) and the two
other PostgreSQL BM25 extensions (**VectorChord-bm25**, **Timescale
pg_textsearch**).  All four engines built from source and measured on a single
freshly-provisioned box in one session — no reused numbers.

## Environment
- EC2 **r7i.4xlarge** (16 vCPU Sapphire Rapids, 123 GB), Fedora 43, 1 TB gp3 at
  `/data` (PGDATA + corpus on real disk, never tmpfs).
- PostgreSQL **17.10** built from source (`--without-icu`, `-O2`).
- `shared_buffers=32GB`, `maintenance_work_mem=8GB`, `work_mem=256MB`, `jit=off`,
  `autovacuum=off` during runs, `max_parallel_maintenance_workers=8`,
  `max_parallel_workers_per_gather=8`.  (`fsync/synchronous_commit/full_page_writes=off`
  for build/load speed — no effect on the warm-cache read latencies measured.)
- Corpus: `wikimedia/wikipedia` 20231101.en, first **2,188,038** articles, `body`
  column.  Invalid UTF-8 cleaned with `iconv -c` (0 rows lost, 6.59 GB → clean
  TSV of exactly 2,188,038 lines).  Loaded `FORMAT csv, DELIMITER E'\t',
  QUOTE E'\x01', ESCAPE E'\x01'`.
- Latency: **median of 9, warm cache, one engine at a time.**  Server-side
  `EXPLAIN (ANALYZE, TIMING off, SUMMARY on)` Execution Time (excludes client RTT).
- pg_fts ranked scans forced onto the AM ordering path
  (`enable_seqscan=off`, `enable_bitmapscan=off`, `max_parallel_workers_per_gather=0`)
  and **EXPLAIN-confirmed as `Index Scan ... Order By`, not the operator
  fallback** (see raw plans below).  Indexes **compacted with `fts_vacuum` and
  the docs table VACUUMed before ranked measurement** so the pending-list
  limitation does not skew recall/latency.

Term frequencies (identical across both pg_fts versions, from `fts_count`):
`slovakia`=**10,874** (rare), `hungary`=**24,095** (mid), `year`=**734,881** (common).

Engine APIs (Snowball `english` analyzer for pg_fts, pg_textsearch, and
VectorChord → comparable stemming/stopwords):
- **pg_fts** (both versions): AM `fts`, `CREATE INDEX ... USING fts (to_ftsdoc('english',body))`;
  match `@@@`, ranked `ORDER BY to_ftsdoc(...) <=> to_ftsquery('english','q') LIMIT k`.
- **pg_textsearch 1.4.0-dev**: `USING bm25(body) WITH (text_config='english')`;
  `ORDER BY body <@> 'q' LIMIT k`.
- **VectorChord-bm25 HEAD** (+ pg_tokenizer): `tsvector` column
  `to_tsvector('english',body)`, `USING bm25 (emb bm25_ops)`,
  `SELECT set_config('bm25.limit','k',false)`,
  `ORDER BY emb <&> to_bm25query(to_tsvector('english','q'),'idx'::regclass) LIMIT k`.

---

## Part 1 — pg_fts v0.2.0 → v0.2.2 before/after (the primary result)

**Correction to the task framing:** v0.2.0 already used AM name `fts` (not
`bm25`) with identical `@@@` / `<=>` operators; `bm25` was the 1.20-era internal
name.  So this A/B is a pure C-code before/after on the *same* AM, operators,
index format, corpus, and box.

### Index size + build (identical, as expected — P1-P4 reverted, format back to v2)

| metric                          | v0.2.0        | v0.2.2        |
|---------------------------------|--------------:|--------------:|
| `CREATE INDEX` build            | 1977 s (33.0 min) | 2014 s (33.6 min) |
| fresh index (pre-compaction)    | 14,683,709,440 B (14.0 GB) | 14,676,762,624 B (14.0 GB) |
| compacted floor (post `fts_vacuum`) | 4,340,416,512 B (**4139 MB**) | 4,340,416,512 B (**4139 MB**) |
| segments after compaction       | 1             | 1             |

The compacted index is **byte-identical (4,340,416,512 B)** between the two
versions and **~1.8× smaller than the 1.20-era 7541 MB** in
`RESULTS_VS_VCHORD_PGTEXTSEARCH.md` — the format-v2 revert (P1-P4 removed)
roughly halved the on-disk size.  `fts_vacuum` still reclaims: a full VACUUM of
the docs table auto-compacts the fresh 14 GB index to 4139 MB, one segment.

**`fts_vacuum` convergence note (matches HANDOFF §5.1):** an explicit
`fts_vacuum` pass on the already-compacted 4139 MB index *grew* it to 8279 MB
(1595 s), and a **second** pass brought it back to 4139 MB (1596 s).  The
low-page-biased rewrite oscillates; the compacted floor is 4139 MB and is
reached, but not monotonically in one pass at 2M scale.

### Ranked latency, median-of-9 (ms) — v0.2.0 vs v0.2.2

| query (band)                 | v0.2.0 | v0.2.2 | Δ (v0.2.2 − v0.2.0) |
|------------------------------|-------:|-------:|--------------------:|
| top-10 rare (slovakia)       | 12.37  | 12.74  | +0.37 (+3%)  |
| top-10 mid (hungary)         | 9.97   | 10.33  | +0.35 (+4%)  |
| top-10 common (year)         | 35.11  | 35.46  | +0.34 (+1%)  |
| top-10 **single-term OR** (year) | 34.37 | 35.70 | +1.33 (+4%) |
| top-10 **AND** rare&mid (slovakia&hungary) | 19.16 | **24.48** | **+5.32 (+28%)** |
| top-10 **AND** common&mid (year&hungary)   | 13.27 | **36.82** | **+23.55 (+177%)** |
| top-100 common (year)        | 63.22  | 66.04  | +2.82 (+4%)  |
| top-100 **AND** common&mid   | 43.53  | **67.65** | **+24.12 (+55%)** |

### Counts, median-of-9 (ms) — v0.2.0 vs v0.2.2

| query         | v0.2.0 | v0.2.2 | Δ |
|---------------|-------:|-------:|--:|
| `fts_count` rare (slovakia)   | 0.90  | 0.87  | ~0 |
| `fts_count` common (year 735k)| 34.70 | 34.74 | ~0 |
| `count(*)` pushdown rare      | 25.59 | 24.24 | −1.4 |
| `count(*)` pushdown common    | 308.60| 289.95| −18.7 |

`fts_count` and the COUNT pushdown are **unchanged** by the v0.2.2 work (small
deltas are noise / favor v0.2.2).

---

## Did the v0.2.2 correctness fixes cost ranked latency? — Yes, but only on AND/phrase.

The two v0.2.2 fixes are (a) ranked `<=>` now filters to the boolean `@@@` match
set for AND/NOT (`bm25_collect_matches` + `DocidFilter`), and (b) phrase/regconfig
now stores positions + rechecks adjacency.  Measured effect:

- **Single-term / pure-OR paths: no cost.**  `single_OR_year` 34.37 → 35.70 ms
  and `common_year` 35.11 → 35.46 ms are within run-to-run noise.  This confirms
  the **NULL-filter fast path**: when there is no boolean AND/NOT to enforce,
  `bm25_collect_matches` is skipped and v0.2.2 costs the same as v0.2.0.
- **AND paths: real, measurable cost.**  The boolean-filter now runs
  `bm25_collect_matches` to build the match set the ranked scan filters against:
  - AND rare&mid: **+5.3 ms (+28%)**
  - AND common&mid top-10: **+23.5 ms (+177%)** — the largest regression
  - AND common&mid top-100: **+24.1 ms (+55%)**
  The cost scales with how many candidates the AND touches (common&mid is the
  worst because `year` alone brings 735k postings into the collect pass).

This is the price of correctness — see the phrase result below for *why* it is
worth paying.

---

## Phrase adjacency at 2M scale — the correctness fix, verified

| version | `"united states"` (phrase `@@@`/count) | `united & states` (AND) | verdict |
|---------|-----------------------------------------:|------------------------:|---------|
| v0.2.0  | **411,011**                              | 411,011                 | phrase == AND (adjacency **NOT** enforced) |
| v0.2.2  | **361,294**                              | 411,011                 | phrase < AND (adjacency **enforced**) ✓ |

In v0.2.0 a phrase query returned exactly the AND count — it did not enforce word
adjacency at all.  **v0.2.2 correctly returns fewer** (361,294 < 411,011): the
phrase now matches only documents where "united" is immediately followed by
"states", confirmed at full 2M scale.  The match counts for the plain bands
(`slovakia` 10,874, `hungary` 24,095, `year` 734,881) are **identical** between
v0.2.0 and v0.2.2 — no correctness regression elsewhere.

---

## Part 2 — v0.2.2 vs the competition (all four freshly built this run)

### Index size + build

| engine        | index size | build | analyzer |
|---------------|-----------:|------:|----------|
| VectorChord   | **1453 MB** | tsvector 705 s + index **31 s** | english (tsvector) |
| pg_textsearch | 1885 MB    | **247 s (4.1 min)** | english |
| pg_fts v0.2.2 | 4139 MB    | 2014 s (33.6 min) + `fts_vacuum` | english, **stores positions** |

### Ranked top-10 (ms, median-of-9, lower is better)

| query           | pg_fts v0.2.2 | pg_textsearch | VectorChord |
|-----------------|--------------:|--------------:|------------:|
| rare (slovakia) | 12.74         | 2.40          | **3.83**    |
| mid (hungary)   | 10.33         | **2.48**      | 4.18        |
| common (year)   | 35.46         | 11.34         | **4.39**    |

### Ranked top-100 (ms)

| query         | pg_fts v0.2.2 | pg_textsearch | VectorChord |
|---------------|--------------:|--------------:|------------:|
| common (year) | 66.04         | **13.87**     | 23.68       |

### Ranked AND top-10 (ms)

| query      | pg_fts v0.2.2 | pg_textsearch* | VectorChord* |
|------------|--------------:|---------------:|-------------:|
| rare&mid   | 24.48         | **2.88**       | 6.20         |
| common&mid | 36.82         | **6.72**       | 13.01        |

\* pg_textsearch and VectorChord have no boolean AND; the "AND" columns are their
bag-of-words rank over the two terms (`'year hungary'`) — ranking-only, so they
score every document and never enforce the strict AND that pg_fts's `@@@` does.
The comparison is ranked-latency-for-a-two-word-query, not like-for-like semantics.

### Counts (ms) — pg_fts-only capability

Neither competitor exposes a match/count predicate (both ranking-only).  Only
pg_fts answers `count(*) ... WHERE @@@` from the index:

| query         | pg_fts `fts_count` | pg_fts `count(*)` pushdown |
|---------------|-------------------:|---------------------------:|
| rare          | 0.87               | 24.24                      |
| common (735k) | 34.74              | 289.95                     |

---

## Honest verdict — where v0.2.2 stands

**Against v0.2.0 (the real headline):** v0.2.2 is a **correctness release, not a
regression release, but the correctness costs AND-query latency.**
- Index size, build time, single-term/OR ranked latency, and all counts are
  **unchanged**.
- The boolean-filter fix adds **+28% to +177%** on AND ranked queries (worst on
  common&mid: 13.3 → 36.8 ms) because `bm25_collect_matches` now runs a match
  pass the ranked scan filters against.  The NULL-filter fast path keeps
  single-term/OR free.
- The phrase fix is real and verified at 2M: `"united states"` now returns
  361,294 (adjacency-enforced) vs v0.2.0's incorrect 411,011 (== AND).  v0.2.0
  phrase results were silently wrong; v0.2.2's are correct.
- Bonus: the format-v2 revert makes the compacted index **4139 MB vs the
  1.20-era 7541 MB (~1.8× smaller)**, and ranked latencies are modestly *better*
  than the 1.20 numbers (common top-10 35.5 vs 39.9, top-100 66 vs 74).

**Against VectorChord and pg_textsearch:** unchanged story from
`RESULTS_VS_VCHORD_PGTEXTSEARCH.md` — pg_fts trails on ranked latency, size, and
build.
- **pg_textsearch** is the ranked-latency leader at top-10 (2.4-11.3 ms,
  ~3-5× faster than pg_fts) and clearly fastest at top-100 (13.9 ms).
- **VectorChord** is ~3-4 ms flat at top-10 (fastest on common single-term:
  4.4 vs pg_fts 35.5); its top-100 on this HEAD build was 23.7 ms (slower than
  pg_textsearch's 13.9, unlike the 1.20-era run where vchord's `bm25.limit`
  early-termination gave ~1.9 ms — this newer build behaves differently at k=100).
- **pg_fts v0.2.2** is 3-8× slower on ranked, ~2.2-2.8× larger, ~8× slower to
  build (positions by design) — but is the **only** engine with an index-native
  `count(*)`/`fts_count`, and the only one enforcing strict boolean AND, phrase
  adjacency, NEAR/prefix/fuzzy/regex over one operator.  The v0.2.2 AND
  regression widens the ranked gap specifically on boolean queries.

**Bottom line:** v0.2.2 is the version you ship — it fixes a real phrase-adjacency
correctness bug and halves the index vs 1.20 — at the cost of AND-query latency
that a future compact-codec + early-termination rewrite (ROADMAP "format v3")
would need to recover.  On raw ranked QPS the Rust engines still win; pg_fts's
niche remains rich query language + correctness + index-native count.

---

## Raw EXPLAIN confirmations (ranked path is the AM ordering scan, not the fallback)

pg_fts v0.2.2 (rare):
```
 Limit
   ->  Index Scan using docs_fts on public.docs
         Index Cond: (to_ftsdoc('english',body) @@@ '''slovakia'''::ftsquery)
         Order By:   (to_ftsdoc('english',body) <=> '''slovakia'''::ftsquery)
```
pg_fts v0.2.0 (rare): identical `Index Scan ... Order By` plan.
pg_textsearch: `Index Scan using docs_pgts ... Order By (body <@> ...)`.
VectorChord: `Index Scan using docs_vchord ... Order By (emb <&> ...)`.

## Raw medians (all runs, ms)

```
pg_fts v0.2.2:
  top10  rare=12.74 mid=10.33 common=35.46  single_OR=35.70  AND_rare_mid=24.48  AND_common_mid=36.82
  top100 common=66.04  AND_common_mid=67.65
  fts_count rare=0.87 common=34.74   count(*) rare=24.24 common=289.95
pg_fts v0.2.0:
  top10  rare=12.37 mid=9.97  common=35.11  single_OR=34.37  AND_rare_mid=19.16  AND_common_mid=13.27
  top100 common=63.22  AND_common_mid=43.53
  fts_count rare=0.90 common=34.70   count(*) rare=25.59 common=308.60
pg_textsearch: top10 rare=2.40 mid=2.48 common=11.34  top100 common=13.87  AND rare_mid=2.88 common_mid=6.72
VectorChord:   top10 rare=3.83 mid=4.18 common=4.39   top100 common=23.68  AND rare_mid=6.20 common_mid=13.01
```

*Measured: EC2 r7i.4xlarge, PostgreSQL 17.10, 2,188,038 Wikipedia articles,
median-of-9 warm, one engine at a time.  pg_fts v0.2.2 (`5041c11`) / v0.2.0 /
VectorChord-bm25 HEAD / Timescale pg_textsearch 1.4.0-dev.  Instance
(terminated), terminated at end of run.*
