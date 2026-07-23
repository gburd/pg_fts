# pg_fts benchmark plan — 4-way, competitive-dimension matrix (2026-07)

Supersedes the ad-hoc 3-way in `bench/RESULTS_VS_CURRENT.md` (0.3.5-era,
expression-index form). Goal: measure the dimensions adopters actually compare
on, with the methodology artifact removed, and add ParadeDB pg_search.

## Engines (4-way + native baseline)
- **pg_fts** current HEAD (rebuild the number; 1.0.x was hardening, but re-run).
- **ParadeDB pg_search** (Tantivy) — NEW to the matrix. Pin a released tag.
- **Timescale pg_textsearch** — the native-C comparator.
- **VectorChord-bm25** — the tsvector-over-BM25 comparator.
- **native `tsvector`+GIN+`ts_rank`** — the built-in baseline everyone beats
  (context, not a peer).

## Methodology — fixes over the prior run (these are the point)
1. **Stored-column form, not expression index.** Prior runs used
   `ORDER BY to_ftsdoc(body) <=> q`, which re-tokenizes+stems the whole body
   PER RETURNED ROW in the executor — 40–88% of pg_fts's "latency"
   (`PROFILE_STEP0.md`), OUTSIDE the index scan. Precompute a stored column
   (`ftsdoc` for pg_fts, `tsvector` for VChord, pg_search's own field, etc.) and
   `ORDER BY col <=> q`. **Report both forms, labeled** — the delta IS the
   re-analysis tax and it must stop distorting the headline.
2. **Matched analyzer** across engines where possible (PG Snowball `english`).
   Tantivy's tokenizer differs; configure pg_search to a Snowball-equivalent, or
   accept + document that its recall/ranking are analyzer-relative (as we
   already do for VChord).
3. Keep prior rigor: EC2 r7i.4xlarge, PG matched, warm median-of-9 (1 discarded),
   one engine at a time, cache warmed, index compacted/VACUUMed before timing,
   EXPLAIN-confirmed plans. Corpus: 2.19M Wikipedia (comparable to history) PLUS
   a dense-technical corpus (mailing-list/patch text) — index-size-vs-source
   varies a lot by content type and the field users run the dense kind.

## Dimension matrix (measure each; do not collapse to one number)
| # | Dimension | Why it matters | How |
|---|---|---|---|
| 1 | Index size (compacted) | adopters compare | pg_relation_size after full compaction |
| 2 | Build time + PEAK build memory | ops/maintenance-window sizing (field ask) | wall-clock; sample RSS+swap of all build procs |
| 3 | Ranked top-k latency | headline speed | rare/mid/common df bands, k=10/100, STORED-COLUMN form |
| 4 | Ranked QPS under concurrency | "under load" — NEVER measured before | pgbench N clients, ranked query mix |
| 5 | Capability matrix | pg_fts/pg_search win breadth | count(*), phrase, boolean AND/NOT, prefix/fuzzy/regex, facets — presence per engine |
| 6 | Correctness | pg_fts differentiator | vs native to_tsvector where analyzers match |
| 7 | Concurrent write + query | the A1 hazard + real workloads | churn (INSERT+merge) while ranked/count runs; assert stable correct results |
| 8 | Recall / ranking quality | BM25 k1/b + analyzer change RESULTS, not just speed | NDCG / P@k on a labeled set |

Dimensions 4, 7, 8 are new and are where "production quality under load" is
actually decided — prior benchmarks measured only 1–3+5–6.

## What we expect it to show (and where it points our focus)
- pg_fts: leads capability (5) + correctness (6); trails size (1), ranked
  latency (3), and likely QPS-under-load (4). pg_search competes on capability
  too (phrase/boolean/facets) — the most interesting head-to-head.
- Focus list the matrix should validate (all already-scoped ROADMAP levers):
  - **Size** → doclen sidecar (ROADMAP P1, ~40% smaller).
  - **Common-term ranked latency** → impact-ordered postings + hard top-k (P4).
  - **Write QPS under concurrency (dim 4)** → metapage-lock INSERT fastpath
    (GIN-fastupdate-style; concurrency audit finding 1.1).
  - **Correctness under load (dim 7)** → the A1 scan-vs-merge page-recycle gate.
- Adoption on-ramp (not a perf lever but a competitive gap): a
  `to_ftsdoc(tsvector)` overload / tsvector-input opclass so an existing
  tsvector column can adopt pg_fts without re-analyzing from source (VChord's
  on-ramp). Low-risk, format-preserving.

## Deliverable
One results note per corpus with the full matrix, both query forms labeled, the
capability grid, and an explicit "where pg_fts loses / wins" verdict — the honest
read, per the competitive-landscape note. Do NOT quote a single engine number
without the form label.
