# pg_fts — what remains for a 1.0.0 production release

Assessment as of v0.3.6 (2026-07-14).  Honest gate: what a *production* 1.0.0
of a PostgreSQL index access method must clear, what pg_fts already clears, and
what is left.  Grouped by must-fix (blocks 1.0) / should-fix / nice-to-have.

## Already cleared (the strong parts)

- **Correctness core**: 100% of page writes via GenericXLog (WAL/crash-safe);
  MVCC + per-segment tombstones; `CREATE INDEX CONCURRENTLY` / `REINDEX
  CONCURRENTLY`; crash-recovery + physical-replication TAP tests; isolation
  tests. Byte-correct across 14 scripts / encodings vs native `to_tsvector`
  (UTF-8) and under LATIN1 / EUC_JP servers.
- **Memory safety**: the on-disk parse surface (FOR codec, doc validator, block
  decoder) is fuzzed under ASan+UBSan with planted-bug "teeth"; three crash
  classes were found + fixed (0.3.3/0.3.4/0.3.5). ≥90% line-coverage gate.
- **Portability**: builds on PG 17 / 18 / 19; PGXS + Nix flake; x86-64, ARM64,
  RISC-V; Linux/FreeBSD/Windows.
- **Packaging / hygiene**: on PGXN; semver releases; CHANGELOG; CONTRIBUTING /
  SECURITY / CODE_OF_CONDUCT; docs render + publish; history scrubbed of infra
  leaks; installable on any server encoding (0.3.6, ASCII install SQL + guard).
- **Query surface**: boolean / phrase / NEAR / prefix / fuzzy / regex over
  `@@@`; ranked `<=>`; index-native `count(*)` / `fts_count`; BM25 + variants +
  BM25F; anomaly SRF. All documented; results == native where comparable.

## MUST fix before 1.0.0 (correctness / operability blockers)

1. **`fts_vacuum` oscillation + non-interruptibility.** A compaction pass can
   *grow* the index before re-converging (measured 4188->8376->4188 MB), and at
   2.19M it ran >40 min CPU-bound and **did not respond to `pg_cancel`**
   (RESULTS_ENCODING.md, RESULTS_VS_CURRENT.md, HANDOFF §5.1). For a production
   index this is the single biggest operability risk: a maintenance command that
   can transiently double the on-disk size and cannot be cancelled. 1.0 needs a
   converging compaction and a `CHECK_FOR_INTERRUPTS()` in the compaction loop.

2. **A clean, one-command test story that runs EVERYTHING.** Until now the TAP
   tests (crash recovery, replication, corruption, encodings) SKIPPED under the
   flake (stock nixpkgs PG lacks `--enable-tap-tests`); they ran only in CI,
   non-gating. The flake now has `tap-pg17`/`tap-pg18` checks (this change), so
   `nix flake check` exercises regression + isolation + TAP. 1.0 wants these
   green and gating on both forges (the CI TAP step is still `continue-on-error`
   due to runner-harness flakiness — make it reliable + gating).

## SHOULD fix before 1.0.0 (quality / trust)

3. **Ranked-latency + index-size gap, framed honestly (not necessarily closed).**
   pg_fts trails pg_textsearch/VectorChord ~2.2-2.9x on index size and, on the
   realistic stored-`ftsdoc`-column query form, ~1.5-2.4x on ranked top-10
   (much of the historical "gap" was the `to_ftsdoc(body)` re-analysis artifact,
   PROFILE_STEP0.md). 1.0 does NOT require matching them — it requires the docs
   to state the trade honestly (capability/correctness/nativeness vs raw
   ranked-QPS/size) and to recommend the stored-column form. The size lever
   (doclen sidecar) and latency lever (impact-ordered codec) remain ROADMAP
   items, both format changes, both benchmark-gated — post-1.0 unless a
   sponsor needs them.

4. **`FtsCount` CustomScan is priced out by its own cost model** so the planner
   never chooses it (falls back to the still-index-native Bitmap Index Scan).
   Not a capability loss, but a rough edge: either fix the cost model or remove
   the unused CustomScan to reduce surface. Low risk; do before 1.0 for polish.

5. **PG 19 is `continue-on-error` in CI.** 1.0 should either fully support and
   gate PG 19 (it's the version with the `table_index_*` flags param) or state
   the supported-version matrix explicitly (17-18 gated, 19 best-effort).

## NICE-TO-HAVE (post-1.0 is fine)

6. Faceting / aggregation pushdown (competitor parity, not core).
7. Parallel ranked scan (measured Amdahl-capped; reverted once — leave).
8. A page recycler so `fts_merge` shrinks the physical file without REINDEX
   (today merge is logical-only; REINDEX reclaims). Ties into #1.

## The 1.0.0 bar, in one line

pg_fts is *functionally* 1.0-ready — correct, crash-safe, portable, well-tested,
honestly documented.  The two things that genuinely gate a **production** 1.0
are operability, not features: **(1) a converging, interruptible `fts_vacuum`**,
and **(2) the full test suite (incl. TAP) green and gating on both forges**.
Everything else is either already done, an honest-documentation task, or a
post-1.0 performance lever.
