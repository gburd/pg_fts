# Ranked top-k slow after scattered deletes; the BMW clamp from jimdawdy-hub (2026-11-02)

**Current.**  Two fixes (CHANGELOG Unreleased), measured on one EC2 host.  Scripts and raw logs are in
`data_churn_2026-11-02/`.

1. **The churn slowdown.**  Reported 2026-11-02 from a production index:
   - 1.88M rows, `doclen_sidecar = off`;
   - after moving 23,313 rows, `fts_vacuum` and VACUUM;
   - ranked top-k became 60-300x slower than on a fresh build of the same rows;
   - REINDEX restored it.
2. **A wrong top-k in two- and three-term ORs.**  The block-max WAND "always make progress"
   clamp.  Found and fixed by Jim Dawdy in the jimdawdy-hub/pg_fts fork (e4bba08), which
   was never submitted upstream.

## Method

- **Host:** c6id.metal (Xeon Platinum 8375C), Debian 13, PostgreSQL 18.6 built from
  source with `-O2`.
  - Turbo off, `performance` governor, THP `never`.
  - **Pinned:** server on node 0 cores 8-15, psql on cores 16-17.
- **Builds:** the same tree with the fixes added one at a time (E is what was committed):

  | build | contents |
  |---|---|
  | A | 1.15.1 C code (1b3ca35) |
  | B | A + the sparsemap cursor fix |
  | C | B + per-scan tombstone checkpoints, a first version: every 64th tombstone |
  | D | B + 1,024 docid-spaced checkpoints, the `fts_anomalous_docs` cursor and the BMW change |
  | E | the final tree: D + `sm_maximum` computed once per checkpoint build, review nits, the `ranked_tombstones` test |

- **Correctness:** at every stage, the md5 of `remove`'s top-200 ids is equal across all
  five builds.  The `vacuum` and `patch` results were not compared (only timed); the new
  regression test `ranked_tombstones` checks shapes like them against an oracle.

## 1. Reproduction (`churn.sh`)

**Table:** 1.9M rows of about 150 words each, drawn log-uniformly over 200k words.
`remove` is in 6% of rows, `vacuum` in 1%, `patch` in 0.5%.  The index is
`to_ftsdoc('english', head || ' ' || own)` with `doclen_sidecar = off`, as in the report.
The heap is 210,366 blocks and the index 905 MB.

**Stages:**

| stage | what happens |
|---|---|
| S0 | fresh build |
| S1 | move every 80th original row to a new id, in 24 transactions (23,750 rows, scattered over the whole heap) |
| S2 | `fts_vacuum`; the dead heap rows are still present |
| S3 | `VACUUM`: bulkdelete tombstones the 23,750 docids on the packed segment (the production end state) |
| S4 | `fts_vacuum` again; it keeps a single packed segment as it is, so the tombstones stay |
| S5 | a second move cycle, then `fts_vacuum` and `VACUUM` |
| S6 | `REINDEX` |

**Timings:** ranked `ORDER BY <=> LIMIT k`, median of 5 warm runs, in ms.

| stage | A: remove200 / vacuum200 / patch10 | B | C | D | E (final) |
|---|---|---|---|---|---|
| S0 fresh | 54.3 / 10.4 / 0.34 | 54.4 / 10.4 / 0.34 | 54.0 / 10.4 / 0.34 | 54.0 / 10.4 / 0.34 | 54.0 / 10.4 / 0.35 |
| S2 packed, no tombstones | 228 / 37.2 / 0.34 | 228 / 37.1 / 0.34 | 227 / 37.0 / 0.34 | 227 / 37.0 / 0.35 | 226 / 37.0 / 0.35 |
| **S3 VACUUM (prod state)** | **3,640 / 238 / 62.1** | 247 / 43.6 / 17.9 | 66.6 / 17.0 / 6.08 | 64.0 / 14.7 / 3.83 | **63.6 / 14.5 / 3.51** |
| S4 fts_vacuum again | 3,648 / 239 / 62.2 | 247 / 44.1 / 18.0 | 66.7 / 17.1 / 6.09 | 64.0 / 14.7 / 3.74 | 63.7 / 14.4 / 3.52 |
| S5 second cycle | 3,646 / 231 / 71.7 | 248 / 44.2 / 18.1 | 68.2 / 17.1 / 6.06 | 65.0 / 14.8 / 3.76 | 64.7 / 14.5 / 3.49 |
| S6 REINDEX | 54.2 / 10.1 / 0.34 | 54.1 / 10.1 / 0.34 | 53.9 / 10.2 / 0.34 | 53.8 / 10.2 / 0.34 | 53.8 / 10.3 / 0.35 |

- **Reproduced on 1.15.1.**  At S3 the slowdown is 67x for remove200 and 183x for
  patch10.  It survives `fts_vacuum` (S4) and is gone after REINDEX (S6), as reported.
  REINDEX is the only workaround measured here; `fts_merge` was not tried.
- **Not the slowdown:** S2 is slower than S0 for remove200 (228 vs 54 ms) on every build.
  The dead heap rows are not tombstoned yet, so their entries are still scored.  That is a
  transient state, and VACUUM ends it.

## 2. Root cause

Each scored posting is checked against its segment's tombstone set, a sparsemap.  A
docid is the heap TID (block x 291 + offset).  A sparsemap chunk covers 2,048 docids,
which is about 7 heap blocks.  So 23,750 deletes spread over 210k heap blocks give about
one chunk per tombstone.  Two lookup costs grew with that chunk count.

1. **The sparsemap cursor ignored a cached chunk that starts after the looked-up index**
   (vendored `sm.c` 5.8.2 `__sm_get_chunk_offset`; 5.8.3 upstream is the same).
   - A lookup that falls in the gap before a chunk caches that chunk, because the walk
     stops at the first chunk that ends after the index.
   - The next ascending lookup in the same gap fails `idx >= cur->start_idx` and walks
     from chunk 0.
   - Live docids tested against sparse tombstones are almost all such lookups.
   - `smgap.c` measures this with one member per chunk and ascending gap lookups, in ns
     per lookup:

     | chunks | 5.8.2 | fixed |
     |---|---|---|
     | 1,000 | 1,537 | 40 |
     | 5,000 | 7,682 | 40 |
     | 20,000 | 30,618 | 39 |

     Lookups inside chunks cost 55-70 ns on both.
2. **The best-first paths reset the cursor for every posting block they visit.**  Blocks
   are visited in bound order, not docid order, and the cursor only resumes forward.  So
   every block's first lookup walked the chunk list from the start.

**Perf, build B at S3:** `__sm_get_chunk_offset` is 88% of patch10 and 75% of remove200
(`prof_fixB.log`).

## 3. Fixes

- **`vendor/sm.c`:** when the index precedes the cached chunk, resume from the chunk's
  left neighbour.  The cursor already records it in `prev_offset`.  The neighbour is used
  only after checking that it ends exactly where the cached chunk begins.
  - `smcheck.c`: 4.06M lookups, cursor equal to no-cursor, ascending and arbitrary order,
    ASan + UBSan.  Raw output of `smgap`, `smcheck` and property 8: `microbench_output.txt`.
  - `test/fuzz/fuzz_smblob.c` property 8 holds the same check plus a time bound: 100,000
    ascending gap lookups over 20,000 chunks.  That takes 4.8 s on 5.8.2, which aborts,
    against milliseconds fixed.
- **`bm25_tomb_seek`:** the first seek in a segment records up to 1,024 tombstones
  spaced evenly by docid, each with an sm cursor on it.
  - Each one is a single `sm_next_member` jump, which skips whole chunks.
  - A block's seek starts from the last checkpoint at or before its first docid.
  - An sm cursor gives the exact answer for any index, so the checkpoints change only the
    cost.
- **`fts_anomalous_docs`:** it checked tombstones with no cursor, one head-walk per
  posting.  It now keeps one forward cursor per term.

**What remains in E:** at S3, patch10 is 3.5 ms against 0.35 fresh.  Perf on E
(`prof_final.log`; `prof_fixC.log` is build C):

| function | share of patch10 |
|---|---|
| `sm_validate` | 25.5% |
| chunk walk (`__sm_get_chunk_offset`) | 19.8% |
| `sm_next_member` | 16.5% |
| `__sm_get_size_impl` | 11.9% |
| `sm_maximum` | 5.9% |

- `sm_validate` is the per-scan corruption check of the tombstone blob, as in 1.15.1.
- `sm_next_member` and `sm_maximum` are the checkpoint build, also per scan.
- Both could be cached per segment generation; that is the open part of ROADMAP I25.

For remove200 (64 vs 54 ms), tombstones are under 10% of the profile.

## 4. The BMW clamp (`r1.sh`, `r1b.sh`, `bmwab.sh`)

**What it did:** `fts_search_bmw` jumped the cursors at or before the pivot to the
earliest end of their current blocks, then clamped that to `pivot + 1`.  When a cursor's
current block ends before the pivot, a later block of that term can score the pivot
higher than the current bound, and the clamp skipped the pivot unscored.

**The fork's test, `bmw_block_end`:** run on its own cluster per build.  The exact top-1
of `aye | bee` is 5000.

| build | PG 17.10 | PG 18.6 |
|---|---|---|
| 1.2.0 (6902bd0) | top-1 = 5000; k=1 not exact (scores differ, not this bug) | same |
| 1.3.0 (d8b32c3) | top-1 = 1, k=1 not exact | same |
| 1.10.0 (8bccf0c) | top-1 = 1, k=1 not exact | same |
| 1.11.0 (93c4b5f) | top-1 = 1, k=1 not exact | same |
| 1.13.0 (90a7194) | top-1 = 1, k=1 not exact | same |
| 1.15.1 (1b3ca35) | top-1 = 1, k=1 not exact | same |
| fixed | passes | passes |

- **The defect starts in 1.3.0.**  1.3.0 to 1.10.0 moved the at-or-before cursors to
  `pivot + 1` unconditionally; 1.3.0's CHANGELOG called that "removing a provably-unsound
  (though not field-reachable) over-skip".  1.11.0 replaced it with the jump to the
  earliest block end and kept `pivot + 1` as a clamp.
- **1.2.0 has a different defect:** it returns the right top-1, but its k=1 score differs
  from the exhaustive reference.  Not investigated.
- Raw results: `r1_versions.txt`, `r1_fix3.log`.

**Cost of removing the clamp** (`bmwab.sh`):
- **Setup:** a 640k-row, 60-token Zipf index; the `.so` swapped under one index; 12
  interleaved samples per build; the fixed tree built twice as an A/A pair.
- **Correctness:** all 16 checks (2- and 3-term ORs, k = 10 and 100, both builds) equal
  the exhaustive top-k scores.

| query | k | 1.15.1 ms | fixed ms | fixed / 1.15.1 | A/A |
|---|---|---|---|---|---|
| `t10 \| t11` | 10 | 16.29 | 16.41 | +0.75% | -0.34% |
| `t10 \| t11` | 100 | 25.65 | 25.96 | +1.19% | -0.78% |
| `t40 \| t300` | 10 | 2.360 | 2.372 | +0.53% | +0.21% |
| `t40 \| t300` | 100 | 2.802 | 2.812 | +0.34% | +0.46% |
| `t10 \| t11 \| t12` | 10 | 48.51 | 49.65 | +2.35% | -1.67% |
| `t10 \| t11 \| t12` | 100 | 49.43 | 50.58 | +2.31% | -1.73% |
| `t200 \| t900 \| t1500` | 10 | 1.169 | 1.185 | +1.33% | -0.97% |
| `t200 \| t900 \| t1500` | 100 | 1.849 | 1.877 | +1.49% | -1.04% |

**Verdict: NOISY.**  The fixed build is slower on every row, by +0.3% to +2.4% (pure ORs;
filtered queries, which also reach this path, were not timed).  The A/A
spread is up to 1.7% in the other direction.  The extra cost is plausible, since the jump
now stops short of the pivot and costs another loop iteration.  It is small next to a
wrong top-k.

## 5. After 1.15.2: `fts_vacuum` expunge and the per-backend memo (2026-11-03)

**The 1.15.2 known issue:** `fts_vacuum` returned false on a single packed segment and kept its tombstones.  Two changes followed on main, measured on the same host and corpus as above:
- **bba830f:** `fts_vacuum` rewrites a single packed segment that carries tombstones.
- **eca5e75:** a per-backend memo of blob validation and checkpoints.

**Churn harness** (`churn2.sh`; `churn_expd.log` is bba830f, `churn_memo.log` is bba830f plus the memo), in ms:

| stage | remove200 / vacuum200 / patch10, bba830f | + memo |
|---|---|---|
| S0 fresh | 54.1 / 10.3 / 0.34 | 54.0 / 10.3 / 0.34 |
| S3 VACUUM (tombstones) | 63.8 / 14.5 / 3.54 | 62.3 / 13.0 / 2.04 |
| `fts_vacuum` | returned t, 88.6 s | returned t, 86.9 s |
| S4 after it | **53.6 / 10.2 / 0.34** | **53.7 / 10.2 / 0.34** |
| S6 REINDEX (183.7 s) | 53.9 / 10.2 / 0.34 | 53.7 / 10.1 / 0.35 |

`fts_vacuum` now restores fresh-build speed in about half the time of a REINDEX.  The top-200 ids equal the other builds' at every stage.

**The memo, measured on its own** (`memoab.sh`, `memoab.log`):
- **Setup:** the S3 state, with the `.so` swapped among bba830f, bba830f built a second time (A/A) and bba830f plus the memo.
- **Timing:** 6 ABBA rounds, 12 samples per build.  Each sample is one psql session of 14 statements, the median of the last 11.
- **Correctness:** ids are identical across builds for all three queries.

| query | bba830f | A/A | + memo |
|---|---|---|---|
| patch10 | 3.490 [3.469-3.506] | +0.01% | **2.020** [2.014-2.045], -42% |
| vacuum200 | 14.41 [14.32-14.47] | -0.08% | **12.95** [12.87-13.06], -10% |
| remove200 | 63.74 [63.61-64.62] | -0.07% | **62.24** [62.15-62.53], -2.4% |
| first query in a session (patch10) | 6.43 | -0.86% | 6.40 (the memo is per backend) |

**The report's repro with both changes** (`report_repro_expunge_memo.log`, `repro_exp.sql`; the report's script with `fts_vacuum` and REINDEX timed):

| step | remove / vacuum / remove bestfirst=off (ms) |
|---|---|
| D | 21.7 / 11.6 / 9.6 |
| E: `fts_vacuum` returned t, 735 -> 728 MB, 69.1 s | **13.9 / 6.8 / 2.0** |
| G: REINDEX, 136.1 s | 14.1 / 6.9 / 2.3 |
| I: moves, VACUUM, no pack (3 segments) | 21.5 / 11.6 / 2.6 |

**At step I:**

| query | time |
|---|---|
| 4-term OR top-200 | 155 ms |
| `count(*)` of 'vacuum' | 3.9 ms |

**What is left:** a backend's first ranked query on a tombstoned segment still validates the blob, and every scan still reads the blob and tests each posting against it.  Between a bulk DELETE + VACUUM and the next `fts_vacuum` or merge, a top-200 costs about 1.15-1.7x a fresh build.
