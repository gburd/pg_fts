# bench/ -- what is current and what is record

`bench/` is a **dated lab notebook**, not documentation. It is kept because the project's
credibility rests on being able to show how every number was produced, which
optimisations were tried and rejected, and which published figures were later retracted.
But 78 files with no index is unreadable, so this file says which ones to trust today.

**Rule:** a new measurement file gets a date suffix and one line here. If it supersedes an
earlier file, say so on both lines. C comments cite the CHANGELOG entry, never a file here.

## Current truth (read these)

| file | what it is |
|---|---|
| `BENCHMARK_SUMMARY.md` | **Start here.** Current numbers vs all measured competitors, the 8-run protocol, the correctness gate, the list of optimisations rejected by measurement, and the record of numbers published wrong and corrected. |
| `../doc/COMPARISON_MATRIX.md` | Feature/perf matrix. Untested competitor capabilities are marked untested, never "No". TIN has a "not in this matrix" note, not a column. |
| `RESULTS_5WAY_159b_2026-09-06.md` | The latest full 5-way single-client latency run (pg_fts / pg_textsearch / pg_search / vchord / GIN). Supersedes every earlier `RESULTS_5WAY_*` and `RESULTS_VS_*`. |
| `RESULTS_C1X_CROSSENGINE_2026-09-11.md` | Concurrent throughput, 1/8/16/32 clients, cross-engine. Includes the correction of the "vchord collapses" claim. |
| `RESULTS_C2_INGEST_2026-09-11.md` | Ingest throughput and pending-list latency curve (pg_fts arm only). |
| `RESULTS_I1_2026-09-18.md` | **Bulk-ingest bloat: root cause found and fixed** (the merge was extend-only and never reused pages), plus two pre-existing deadlocks found and fixed on the way. Zero net growth over 30k and 100k row-per-txn docs; `fts_vacuum` finds nothing to reclaim. M3 (long ingest: no decay, only cycle noise) is appended. Supersedes the mechanism section of `RESULTS_KNOWN_ISSUES_2026-09-14.md`. |
| `RESULTS_KNOWN_ISSUES_2026-09-14.md` | The bulk-ingest bloat investigation as of 1.7.2: mechanism half-right (the XID gate binds only inside a single multi-row statement), 31% mitigation, and the retraction of the "one WAL record per page" claim. **Mechanism superseded by `RESULTS_I1_2026-09-18.md`.** |
| `RESULTS_FIELDSHAPE_2026-09-13.md` | The ~2.87M-doc / 1660-terms-per-doc field shape: the P0 that made an index permanently unvacuumable, its gdb isolation, and the fix. |
| `RESULTS_ABC_2026-09-17.md` | Count-path work: df fast-count tests, block-run VM checking measured at ~1% (kept as cleanup), verbatim-merge-copy withdrawn. |
| `NOTE_VS_TIN_2026-09-14.md`, `NOTE_TIN_FEASIBILITY_2026-09-14.md`, `NOTE_SIMD_VENUE_2026-09-14.md` | Competitive/architectural analysis of PlanetScale's TIN, what of it is reachable, and why SIMD does not belong in the vendored sparsemap. |
| `PLAN_ABC_2026-09-14.md` | The plan behind `RESULTS_ABC`; shows how reading the code moved all three items before implementation. |

## Design notes (still describe the shipped design)

| file | describes |
|---|---|
| `DESIGN_DOCLEN_SIDECAR.md` | The v4 per-segment doclen sidecar and the dual-read upgrade -- the precedent for every future format change. |
| `DESIGN_FIELD_ZONES_v4.md` | Field zones (`term:D` weighting). |
| `NOTE_WAND_PRUNING_2026-09-04.md` | Why WAND is exact here and what it does not prune. |
| `NOTE_RANKED_EXACTNESS_LATENT.md`, `NOTE_RANKED_RECALL.md`, `RANKED_SCAN_CORRECTNESS_INVESTIGATION.md` | The exact-top-k guarantee and its history. |
| `NOTE_PHRASE_POSITIONS.md`, `NOTE_PHRASE_POSITIONS_FIX.md`, `REVIEW_PHRASE_NOPOS.md` | Phrase semantics on positionless documents (1.6.0). |
| `NOTE_STRATEGY_TSVECTOR_HARDENING_UPSTREAM.md` | Relationship to upstream tsvector work. |

## Dated record (superseded or closed; keep for provenance)

**Investigations that are closed.** `P0_VACUUM_HANG_2026-09-10.md` (fixed 1.6.1),
`P1_VACUUM_NO_RECLAIM_2026-09-11.md` and `RESULTS_SELF_LIMITING_2026-09-12.md` (the
cleanup-growth chain, fixed across 1.6.1-1.7.1; four wrong hypotheses recorded honestly),
`RESULTS_P1_SCALE_AB_2026-09-13.md` (showed the P1 did not reproduce at 1M docs),
`DIAG_WORKER_FRAGMENTATION.md` + `REVIEW_WORKER_FRAGMENTATION.md`,
`NOTE_BUILD_FLUSH_QSORT_SPIN.md`, `RESULTS_MERGE_OOM.md`, `RESULTS_MERGE_MEMORY.md`,
`RESULTS_MERGE_VACUUM_DECODE.md`, `RESULTS_VACUUM_SCALE.md`, `RESULTS_SPARSEMAP_2026-09-08.md`,
`RESULTS_PARALLEL_MERGE_2026-09-08.md`, `RESULTS_GATING_2026-09-09.md`,
`RESULTS_ENCODING.md` + `NOTE_ENCODING_REVIEW_2026-09-06.md` (fixed 1.5.9).

**Profiles that motivated shipped changes.** `PROFILE_STEP0.md`, `NOTE_FORMAT_V3_PROFILE.md`,
`NOTE_PROFILE_COMMON_TERM_2026-09-06.md` (the 45%/37% breakdown still quoted),
`NOTE_PHRASE_PROFILE_2026-09-06.md` (the "90.70 ms phrase was not a phrase" correction),
`NOTE_RARE_MID_LATENCY_OPTIONS_2026-09-05.md`.

**Options considered and declined, with the reason.** `NOTE_IMPACT_ORDERING.md` (breaks
docid-ordered count/AND/phrase), `NOTE_META_WAH_ASSESSMENT.md`, `NOTE_PARALLEL_RANKED.md`
(built and reverted), `PLAN_HEAP_POSITIONS_OFF.md` (no-go: ~16% of a compressed column),
`PLAN_PARALLEL_SCAN.md`, `NOTE_ANOMALY_DETECTION.md`, `NOTE_SIZE_AND_SPEED.md`,
`NOTE_SIZE_SPEED_REPLAN.md`, `RESULTS_ANDOPT.md`.

**Superseded benchmark runs** (each replaced by the next; kept so the trend is auditable):
`RESULTS_V022.md`, `RESULTS_130_vs_122.md`, `RESULTS_4WAY.md`, `RESULTS_4WAY_2026-07-29.md`,
`RESULTS_VS_PGSEARCH.md`, `RESULTS_VS_PGSEARCH_WIKI.md`, `RESULTS_VS_VCHORD_PGTEXTSEARCH.md`,
`RESULTS_VS_CURRENT.md`, `RESULTS_WIKIPEDIA_2M.md`, `RESULTS_20M.md`, `RESULTS_BENCH_20M_100M.md`,
`NOTE_CORPUS_20M.md`, `RESULTS_SEGMENTED.md`, `RESULTS_P1_P4.md`, `RESULTS_HARDENING_2026-08.md`,
`RESULTS_5WAY_150_2026-08-28.md`, `RESULTS_5WAY_157_2026-09-01.md`, `RESULTS_5WAY_158_2026-09-04.md`,
`RESULTS_5WAY_159_2026-09-05.md`, `RESULTS_C1_UNDERLOAD_2026-09-11.md` (pg_fts-only precursor
to C1X), `COVERAGE_AUDIT_2026-09-10.md`.

**Historical plans.** `PLAN_4WAY_BENCHMARK.md`, `PLAN_5WAY_LOADED_2026-08.md`,
`PLAN_HARDENING_2026-08.md`, `PLAN_STORAGE_PERF_2026-08.md`, `NOTE_1_0_0_READINESS.md`,
`NOTE_COMPETITIVE_LANDSCAPE.md`.

## Data directories

`data_*` directories hold the raw logs/JSON behind a `RESULTS_*` file of the same date.
They are the evidence and are intentionally tracked. Harness scripts are `*.sh` here
(`underload.sh`, `ingest.sh`, `parity_check.sh`, `soak.sh`, `latency.sh`, `ndcg.py`).
