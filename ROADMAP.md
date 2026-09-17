# pg_fts roadmap

The single plan file. Open work first, in priority order, each with its status and the
evidence behind it. Closed items are one line each; the full record of how they were
closed (and the wrong turns on the way) is in `bench/ROADMAP_HISTORY_2026-09-17.md` and the
files `bench/INDEX.md` lists.

Rules for this file: an item is either **open**, **blocked**, or **closed**. When it closes,
collapse it to one line here and leave the detail in the CHANGELOG. Do not create a second
plan file.

---

## Open -- repository and presentation (from `REVIEW_2026-09-17.md`)

These do not touch the index and are the cheapest, highest-leverage work in the project.

| # | item | status |
|---|---|---|
| R1 | **README comparison paragraph contradicted the project's own table** (claimed a rare-term lead; called the doclen sidecar future work). Rewritten as a wins / loses / caveat structure; every figure grep-verified against `BENCHMARK_SUMMARY.md` and `RESULTS_C1X`. The paragraph now states it is derived from the summary and that the summary wins on disagreement. Rule 27 in `AGENTS.md` and `RELEASING.md` step 1 keep it in sync. | **done 2026-09-17** |
| R2 | **Delete the 31 dead base SQL scripts** in the root. Only `pg_fts--<current>.sql` is installed; the rest were snapshots left by each rename. Verified none referenced by Makefile/meson/flake before `git rm`. `RELEASING.md` step 1 now says `git mv`, not copy. | **done 2026-09-17** |
| R3 | **`bench/INDEX.md`** naming current-truth vs dated-record files. | **done 2026-09-17** |
| R4 | **One plan file.** `HANDOFF`/`DEFERRED`/`CAPABILITIES` folded: DEFERRED (all resolved) and the old ROADMAP moved to `bench/` as history; CAPABILITIES moved to `doc/` (it is user-facing Q&A, not a plan). | **done 2026-09-17** |
| R5 | **C comments no longer cite `bench/` files** (9 sites -> 0). They cite the CHANGELOG release that closed the issue; the journal can be reorganised, the CHANGELOG cannot. | **done 2026-09-17** |
| R6 | **`t/010` in all CI matrices.** Added to GitHub and Forgejo; Forgejo's TAP set was also widened from 2 tests to the same 7 the nix gate runs. `RELEASING.md` step 3 now requires all three places. **Unverified until the next push runs CI on the Forgejo container** -- the wider set may hit the harness limits its comment describes. | **done, CI run pending** |
| R7 | **Agent tooling out of the working tree's face.** `.agent/`, `.claude/`, `.kiro/`, `.mcp.json`, `.agent-steering-domains.md` are gitignored but visible. `AGENTS.md` is now tracked and is the one entry point; the rest stay local. Also found and fixed while doing this: `result-1`, a nix build-output symlink, was **tracked** (now `git rm --cached`, `result*` ignored). | **done 2026-09-17** |

## Open -- code quality (from `REVIEW_2026-09-17.md`)

| # | item | status |
|---|---|---|
| C1 | **Pass allocator state explicitly.** `bm25_lowfree_*` and `bm25_alloc_extend_only` are file-scope globals owned by an implicit `bm25_alloc_begin`/`_end` protocol. Reading them without owning them handed out garbage block numbers in the 1.7.1 work; only `t/007` caught it. Replace with a struct passed to `bm25_new_buffer`. Behaviour-preserving; gate must stay green. | **open** |
| C2 | **Split `bm25_collect_matches` (412 lines).** Every scan goes through it. Extract the per-segment evaluation and the pending-list pass. | **open** |
| C3 | **The 12,000-line translation unit.** `pg_fts_am.c` `#include`s `pg_fts_am_scan.c` and `pg_fts_trgm_index.c` for shared statics. Either keep and document why prominently at the top of each file, or expose the shared state through `pg_fts_am.h` and compile separately. Decide, do not drift. | **open** |

## Open -- index behaviour

| # | item | status | evidence |
|---|---|---|---|
| I1 | **Bulk-ingest write amplification.** At 1,660 terms/doc every document mints a one-doc segment; the insert-time merge rewrites a run per document. Freed pages cannot be reused in the inserting transaction because the recyclability XID gate (correctly) rejects them. 1.7.2 gated the merge on segment pressure: **-31%** (31,537 -> 21,874 MB over six 5k batches). Still **~3.7 GB per 5,000 docs** until `fts_vacuum` (which recovers ~210x in seconds). **Real fix is a design change: merge outside the inserting transaction** so freed pages pass the gate. Not a point release. | **open, mitigated** | `bench/RESULTS_KNOWN_ISSUES_2026-09-14.md` |
| I2 | **Common-term ranked latency -- the competitive gap.** `year` (df 734,896) top-10: **36.16 ms** vs pg_search 2.12, vchord 3.49, pg_textsearch 20.71; 20.7x under load. Profile: 45% doclen path, 37% candidate iteration -- per-posting scalar work. Only **item D** below can close it. | **open, architectural** | `bench/NOTE_PROFILE_COMMON_TERM_2026-09-06.md`, `RESULTS_C1X_CROSSENGINE_2026-09-11.md` |
| D | **Two-level page bitmaps + SIMD** (TIN-style). Format side is tractable via the 1.5.0 optional-per-segment-pointer + dual-read precedent (**no REINDEX**). Real cost: **no SIMD infrastructure exists** (no intrinsics, no runtime dispatch, no `-mavx2` plumbing) and a scalar fallback must be kept for non-AVX and ARM -- two implementations forever. Largest change the project has attempted, against a competitor that cannot be benchmarked. **Needs explicit sign-off.** Do **not** vectorize the vendored sparsemap. | **blocked on sign-off** | `bench/NOTE_TIN_FEASIBILITY_2026-09-14.md`, `NOTE_SIMD_VENUE_2026-09-14.md` |
| I3 | **Managed-service validation** on a compute/storage-separated backend (Aurora-style). GenericXLog-only WAL should be safe; unverified externally. | **open, external** | `doc/CAPABILITIES.md` |
| I4 | **Independent human review of WAL/crash/recovery paths.** Checklist exists in `RELEASING.md`; the review itself is a release-integrator step. | **open, external** | |

## Open -- measurement debt

| # | item |
|---|---|
| M1 | **C2 cross-engine ingest.** Rivals' ingest paths differ fundamentally; needs per-engine forms chosen as carefully as C1X's. |
| M2 | **C3 NDCG vs rivals.** Matters because pg_search (Tantivy) does not stem -- its speed is partly a smaller unit of work. `bench/ndcg.py` exists. |
| M3 | **Longer ingest run** to find where the pg_fts ingest decay (41% over 200k rows) levels off. |
| M4 | **The published competitor set on TIN's exact rig** (i7i.8xlarge, 8 vCPU / 32 GB container, Stack Exchange corpus) plus pg_fts -- places us on their axis without asserting anything about TIN. Several EC2 hours. |

## Declined (with the measurement that declined them)

- **Impact-ordered postings** -- breaks the docid ordering that `count(*)`/AND/phrase/prefix need.
- **Early termination** -- breaks exact top-k.
- **Lazy phrase gate** -- ~1.5x ceiling; adjacency is only 4.3% of the query.
- **Heap-side `positions=off`** -- saves ~16% of a `STORAGE=extended` column; no-go.
- **Parallel ranked scan** -- built, measured, reverted (`bench/NOTE_PARALLEL_RANKED.md`).
- **Parallel merge** -- 1.45x slower and 19% larger at scale; `mpmw=8` silently serial.
- **df-threshold bulk load** -- cost ~linear in df, no fixed floor.
- **Verbatim posting copy on merge** (TIN item C) -- the merge re-encodes through the build hash table; no splice point.
- **Vectorizing sparsemap** -- never a query hotspot; the one time it was the bottleneck (P0, 99.75%) the fix was algorithmic; its compressed layout is SIMD-hostile; it is vendored byte-identical to upstream on purpose.

## Closed (one line each; detail in CHANGELOG)

- **1.8.1** count-path: df fast-count gate tests (10, non-vacuous); block-run VM checking measured ~1%, kept as cleanup.
- **1.8.0** intra-word `-` `.` `/` are terms, not operators (`pkg-config` no longer parses as `pkg & !config`).
- **1.7.2** insert-time merge gated on segment pressure: bulk-ingest growth -31%.
- **1.7.1** `pd_lower` guard generalised to all 8 page-read sites; "one WAL record per page" known issue **retracted** (0.005 ms/page measured).
- **1.7.0** P0: unvalidated `pd_lower` in the merge dict walk made an index permanently unvacuumable at field shape; fixed. Huge-alloc gaps in doclen/tombstone arrays fixed. Cleanup no longer grows the index (18/18/18 MB vs 35/52/69).
- **1.6.1** P0: VACUUM never completed on a delete-heavy index (4h39m -> 393 s; dense tombstone bitmap sized by `sm_maximum`). sparsemap 5.5.1.
- **1.6.0** phrase over positionless docs returns `false`, not a silent conjunction (matches `OP_PHRASE`).
- **1.5.9 / 1.5.10** non-UTF-8 case folding; common-term 1.56x via ascending-resume + word-load `bm25_for_get`.
- **1.5.0** doclen sidecar (format v3 -> v4) with dual-read, **no REINDEX** -- the precedent for all future format changes.
- **COUNT pushdown** (CustomScan), **`fts_search` under-fetch**, **reserved keywords as literals**, **sparsemap error-path leaks**, **recovery guard on `fts_merge`/`fts_vacuum`**, **privilege lockdown**, **recently-dead exclusion from corpus stats**, **parallel-build memory ceiling** -- all shipped; see history file.
