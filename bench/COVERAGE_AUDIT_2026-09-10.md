# Competitive coverage audit — what we can and cannot claim (2026-09-10, v1.6.1)

An honest inventory of the dimensions normally used to judge a PostgreSQL BM25 index
access method, and whether pg_fts has **evidence** on each against **all** rivals.
Written because the published comparison (`doc/COMPARISON_MATRIX.md`,
`bench/BENCHMARK_SUMMARY.md`) is strong on some axes and silent on others, and the
silence was not previously stated.

Comparators: `pg_textsearch` (Timescale), `pg_search` (ParadeDB/Tantivy),
`VectorChord-bm25`, and built-in `tsvector`/GIN.

---

## Summary: two axes remain unmeasured (was three; concurrency is now answered)

**Update 2026-09-11:** concurrency is measured and it is a *win* on shape — pg_fts
scales 10.7x to 32 clients where vchord collapses. C2 (ingest) and C3 (quality) remain
unmeasured.

| dimension | evidence vs all rivals? | where we stand |
|---|---|---|
| Single-client ranked latency | **Yes** | mixed: win rare vs pg_textsearch, lose common-term badly |
| Index size | **Yes** | **best in field** (1,421 MB vs 1,887 / 2,734 / 2,902) |
| Build time | **Yes** | slowest of the stemming engines (381 s vs 496 / 127 / 56) |
| Exact `count(*)` | **Yes** | **best**, and two rivals cannot do it at all |
| Match-count correctness | **Yes** | correct English stemming; pg_search is 33% low |
| Query-language breadth | **Yes** | **widest by a large margin** |
| **Concurrent throughput (QPS)** | **YES for pg_fts (2026-09-11); cross-engine re-run pending** | **scales 10.7x to 32 clients, no cliff** |
| **Ingest / update throughput** | **NO — never measured for anyone** | unknown |
| **Ranking quality (NDCG)** | **NO — never measured vs rivals** | unknown |
| Crash/MVCC/replication safety | ours only | ours tested hard; rivals **untested by us** |
| Big-endian | **no** | untested anywhere in CI |

---

## Gap 1: concurrent throughput — ANSWERED 2026-09-11, and my claim below was WRONG

**Correction.** This section said pg_fts's under-load arm was missing. It was not:
`bench/data_5way/ftsx_underload.txt` has had our numbers since Aug 27, showing
**10.0x scaling from 1 to 32 clients** — the best factor in the field. The corrupt file
(`bench/data_soak_bench/bench_ftsx_sidecar.json`) is from a *different* run, and I
conflated the two.

Re-measured on v1.6.1 (`bench/RESULTS_C1_UNDERLOAD_2026-09-11.md`): **10.7x on rare
ranked, 9.9x on common ranked**, throughput still rising at 32 clients, latency flat
from 1 to 8 clients. **pg_fts does not have vchord's collapse.** The scaling risk this
section raised is closed; what remains open is a like-for-like cross-engine re-run on
current versions with one documented query form.

Original text follows for the record.

## Gap 1 (original, partly wrong): concurrent throughput

`bench/data_soak_bench/` contains a genuine under-load comparison at 1/8/16/32
clients with p95/p99, and **three of four engines have it**:

| engine | rare k10 @1 client | @8 | @16 | @32 |
|---|---|---|---|---|
| pg_textsearch | 1,234 tps / 0.81 ms | 8,544 / 0.94 | 8,255 / 1.94 | 8,484 / 3.77 |
| pg_search | 701 tps / 1.43 ms | 5,295 / 1.51 | 6,694 / 2.39 | 7,071 / 4.53 |
| vchord | 473 tps / 2.12 ms | 1,260 / 6.35 | 1,178 / 13.58 | 1,160 / 27.58 |
| **pg_fts** | **missing** | — | — | — |

`bench_ftsx_sidecar.json` is **truncated mid-JSON** (940 bytes, no closing brace) and
contains a `latency` block only — **no `under_load` key at all**. So the one
competitive dataset that measures scaling behaviour is the one where our own arm is
absent.

Worse, its latency figures are from the **1.5.0 era** (rare 14.83 ms, common 53.61 ms)
and are obsolete: v1.6.1 measures rare **5.89 ms** and common **36.16 ms**. Publishing
from that file would understate us by ~2.5x on rare.

**What the rival numbers suggest, and why it matters:** vchord's throughput *collapses*
under concurrency (1,260 → 1,160 tps from 8 to 32 clients, latency 6.35 → 27.58 ms)
while pg_textsearch and pg_search scale to 8,500 and 7,000 tps. That is a
first-order production property and we have no idea which pattern pg_fts follows.
Single-client medians — everything we currently publish — cannot answer it.

**This is the single most important missing measurement.** A ~2x single-client latency
gap matters much less than a throughput cliff, and we cannot currently rule one out.

## Gap 2: ingest and update throughput — never measured, for anyone

We measure **bulk build** (381 s for 2.19M docs) but not:

- sustained `INSERT` rows/s into a live index (pg_fts appends to a pending list, which
  should be a genuine advantage — untested against rivals)
- `UPDATE`/`DELETE` throughput, and the cost of the tombstone accumulation that
  follows
- how query latency degrades between merges as the pending list grows

The last point is the one a user hits first in production, and we have no curve for it.
Note also that v1.6.1 just fixed a P0 where `VACUUM` never completed on a delete-heavy
index — which means the delete/maintenance path has only *now* become measurable at
all.

## Gap 3: ranking quality (NDCG) — never compared

`bench/ndcg.py` and `bench/NOTE_RANKED_RECALL.md` exist and were used to validate
**our own** ranked exactness (top-k parity against an exact `fts_bm25` sort — a real
guarantee most rivals do not publish). But no NDCG or recall comparison against
pg_search/vchord/pg_textsearch was ever run.

This matters more than usual here because **pg_search does not stem**: it returns
495,580 documents for `year` where the correct English answer is 734,896
(regex-verified). Different result *sets* make a pure latency comparison partly
apples-to-oranges, and a quality measurement is what would quantify that. We assert
correctness (byte-identical counts with the two other stemming engines) but have never
measured *relevance ordering* against anyone.

## Gap 4: robustness comparison is one-sided

pg_fts has extensive crash/MVCC/replication/concurrency testing (TAP suites, the
1.5.7 race fixes, the 1.6.1 P0). We have run **none** of that against the rivals. The
matrix marks their rows `n/t`, which is honest, but it means the robustness axis is
"we are well tested" and not "we are better tested". Any claim of superiority there is
unearned.

## Gap 5: big-endian

sparsemap 5.5.0 fixed a corruption reaching our tombstone iteration on big-endian
hosts. We have **no big-endian CI**, so that platform is untested rather than proven,
for us and for rivals alike.

---

## What we can legitimately claim today

- **Smallest index in the field** — 25% under next best, 2.0x under vchord. Measured,
  identical corpus, post-`fts_vacuum` on both sides.
- **Fastest exact `count(*)`** — 2.20 ms, 6x pg_search; pg_textsearch and vchord
  cannot do it at all.
- **Correct English stemming**, verified against regex ground truth, and byte-identical
  match counts with the two other engines using PostgreSQL's analyzer.
- **Widest query language** — boolean/NEAR/prefix/fuzzy/regex/phrase over one
  operator, plus BM25 variants and BM25F. vchord is ranking-only; pg_textsearch is
  ranked retrieval only.
- **Exact top-k**, gated by `parity_check.sh` on every release.
- **No `shared_preload_libraries` and no Rust toolchain** — a real deployment
  advantage; the other three all require a preload and two require Rust.

## What we must stop implying

- That the comparison is complete. It covers **single-client latency, size and
  correctness**. It does not cover throughput, ingest, or ranking quality.
- That we are competitive "on all dimensions". On the measured axes we win some and
  lose common-term ranked badly (36.16 ms vs 2.12 ms). On three axes we do not know.

## Recommended order of work

1. **Concurrent throughput, all four engines, current versions.** Highest value: it is
   the axis most likely to change the story in either direction, the rig already exists
   (`bench/soak.sh` produced the rival data), and our arm merely needs re-running and
   the JSON writer fixed so it cannot truncate again.
2. **Ingest/update throughput**, including the query-latency-vs-pending-list curve —
   newly meaningful now that the delete path terminates.
3. **NDCG vs rivals**, which also quantifies the pg_search stemming difference.
4. Leave common-term ranked (ROADMAP 4a) until 1 and 2 are known: if we scale well
   under concurrency, a 2x single-client gap is a much smaller problem than it looks.
