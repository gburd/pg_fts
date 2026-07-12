# AND/NOT ranked optimization (lazy boolean) — 2M confirmation + a phrase-count finding

Confirms the lazy-boolean AND/NOT optimization (HEAD `c29432d`) at 2.19M
Wikipedia scale, and records a SEPARATE pre-existing performance cliff found
during the run.

## Environment
- EC2 r7i.4xlarge, Fedora, PostgreSQL 17.10 from source, 2,188,038 Wikipedia
  articles, `shared_buffers=32GB`, warm cache, docs table VACUUMed + index
  fts_vacuum-compacted before measurement. Ranked scans forced onto the AM
  ordering path (`enable_seqscan=off`, `enable_bitmapscan=off`,
  `max_parallel_workers_per_gather=0`), EXPLAIN-confirmed `Index Scan ... Order By`.
- Loaded binary confirmed = HEAD (the `year & !hungary` NOT query ran in 42 ms;
  v0.2.2's collect pass would be ~415 ms).
- Instance (terminated) — TERMINATED.

## PASS — the AND/NOT optimization recovers the regression (and then some)

| query (top-10, ms) | v0.2.0 (pre-regression) | v0.2.2 (regressed) | HEAD c29432d (lazy boolean) |
|--------------------|------------------------:|-------------------:|----------------------------:|
| AND `year & hungary`     | 13.3 | 36.8 | **~1.3** |
| AND `slovakia & hungary` | 19.2 | 24.5 | **~11.0** |
| NOT `year & !hungary`    | (n/a) | ~415 (collect near-universe) | **~42** |

- `year & hungary` top-10: **36.8 → ~1.3 ms** — not just the +177% regression
  recovered, but ~10× better than even v0.2.0, because lazy eval removes the
  collect pass AND block-max WAND prunes hard once the boolean gate is inline.
- `slovakia & hungary`: 24.5 → ~11 ms.
- NOT near-universe: ~415 → ~42 ms (the collect pass of the whole `year`
  posting list is gone).
- Correctness: results are byte-identical to v0.2.2 (the rankparity ground-truth
  test passes unchanged; local A/B was byte-identical). Match counts unchanged.

**Verdict: PASS the kill criterion.** AND/NOT ranked latency drops materially
(well past the v0.2.0 baseline), single-term/OR use the unchanged NULL fast path,
and results are identical. The optimization is sound to ship.

## SEPARATE FINDING — phrase COUNT on a common two-word phrase is pathologically slow

Not caused by this optimization (it touches only the ranked WAND scorers, not
the count/collect path), and present in shipped 0.2.2:

| query | time |
|-------|-----:|
| `count(*) WHERE @@@ '"united states"'` (phrase) | **231,890 ms (3:52)** |
| `count(*) WHERE @@@ 'united & states'` (plain AND, same two words) | **0.24 ms** |
| `fts_count('docs_fts', '"united states"')` | (also slow; same path) |

Both return the correct adjacency-enforced count (361,294 < the AND's 411,011).
Root cause: the 0.2.2 phrase fix routes phrase `@@@`/count through
`bm25_collect_matches` (which returns the AND-set, 411,011 docids) then
`bm25_recheck_exact`, which **fetches every one of those 411,011 heap tuples,
detoasts, and re-runs `fts_doc_matches`** to enforce adjacency — ~411k heap
probes for one count. On a common two-word phrase this is ~4 minutes.

This is the price of the correctness fix, but the *implementation* is a cliff on
common phrases. It affects phrase/NEAR `@@@`, bitmap count, and `fts_count` (all
recheck-based); the RANKED `<=>` phrase path is bounded by LIMIT k so it is far
less affected. RESULTS_V022 measured phrase *correctness* (the count value) but
not phrase count *latency*, so this was missed.

**Recommended follow-up (separate from the AND-opt release):** make phrase
adjacency cheaper than a full heap recheck of the AND-set — e.g. store token
positions in the bm25 index so phrase can be evaluated from postings (a format
change — benchmark-gated), or at least bound/short-circuit the recheck. Tracked
for a future release; not a blocker for shipping the AND-opt (which is a strict
improvement and changes no phrase behavior).

Measured: EC2 r7i.4xlarge, PostgreSQL 17.10, 2,188,038 Wikipedia articles,
warm cache, HEAD c29432d vs v0.2.2 / v0.2.0 (RESULTS_V022 numbers). Instance
terminated.
