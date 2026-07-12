# pg_fts P1–P4 before/after — 2.19M Wikipedia (definitive)

Before/after of the P1–P4 performance series against the **v0.2.0** tag (the
commit immediately before P1). Both versions use the same `fts` access method,
the same SQL, the same `<=>` ranked operator, and the same
`to_ftsdoc('english', body)` functional index — the only difference is the C
posting/format code (v2 → v3 → v4). This is the primary deliverable; the
VectorChord / pg_textsearch columns are reused from the prior 1.20-era run
(`RESULTS_VS_VCHORD_PGTEXTSEARCH.md`) on the identical environment.

## Headline verdict

**P1–P4 regressed pg_fts across the board. None of the predicted wins
materialised at 2.19M scale, and the series introduced one hard build failure
and one ranked-correctness divergence.**

- **P1 (doclen sidecar, format v3): did NOT cut size ~40%. It made the index
  *bigger* — after-build 14.7 GB → 16.2 GB, and compacted 4139 MB → 15 GB
  (fts_vacuum no longer reclaims on v4).** The opposite of the ~40% cut.
- **P2/P3 (redundant per-scan work): did NOT cut rare/mid latency. It rose**
  (rare 13.4 → 21.8 ms, mid 11.2 → 18.4 ms top-10).
- **P4 (impact tiers + hard top-k early-termination): did NOT make common-term
  top-k flat. Common `year` rose (36.9 → 55.5 ms top-10; 67.5 → 86.0 ms
  top-100), and AND queries got much worse (common&mid 14.3 → 167.0 ms).**
- **Build blocker:** committed HEAD (8726525) **cannot build the index at
  2.19M** — the parallel build dies with `invalid memory alloc request size
  1073741824`. See §Build failure. Measured HEAD is a one-line-patched HEAD.
- **Correctness:** counts are identical (year 734881, slovakia 10874, hungary
  24095 on both). Ranked top-k **diverges on AND queries** (HEAD vs 0.2.0) and,
  more seriously, **both versions' ranked index scan is inexact vs a
  brute-force score sort** even on a single common term. See §Correctness.

## Environment
- EC2 **r7i.4xlarge** (16 vCPU Sapphire Rapids, 123 GB), Fedora 44.
- Instance `(terminated)`, us-east-2, tagged `owner=gburd-agent` +
  `Name=pgfts-bench-p1p4-20260708-185251`. **TERMINATED** (confirmed;
  per-session key + SG deleted).
- PostgreSQL **17.10** from source (`--without-icu`, -O2).
- `shared_buffers=32GB`, `maintenance_work_mem=8GB`, `work_mem=256MB`,
  `jit=off`, `autovacuum=off`, `max_parallel_maintenance_workers=8`.
- Corpus: `wikimedia/wikipedia` 20231101.en, first **2,188,038** articles
  (`body`), cleaned invalid UTF-8, loaded `FORMAT csv, DELIMITER E'\t',
  QUOTE E'\x01', ESCAPE E'\x01'`. Both DBs loaded identically (134 s each).
- Two isolated PG prefixes on `/data`: `pg-head` (port 5433, pg_fts@8726525
  patched) and `pg-020` (port 5434, pg_fts@v0.2.0). Both indexes single-segment.
- Latency: median of 9, warm cache, one engine at a time.

## Index size + build (the P1 test)

| version            | build (CREATE INDEX) | size after build | fts_vacuum #1 | size after vacuum |
|--------------------|---------------------:|-----------------:|--------------:|------------------:|
| **pg_fts 0.2.0**   | 2098 s (35.0 min)    | 14677549056 (14 GB) | 1800 s     | **4340416512 (4139 MB)** |
| **pg_fts HEAD**    | 2259 s (37.7 min)    | 16189792256 (15 GB) | 1992 s     | **16189792256 (15 GB, unchanged)** |

P1 predicted 7541 MB → ~4300 MB. Reality: HEAD is **~3.6× larger than the
compacted 0.2.0** (15 GB vs 4139 MB) and slightly slower to build. Two distinct
problems: (1) the v3/v4 format stores *more* per segment (doclen sidecar +
impact-tier directory) not less; (2) **`fts_vacuum` no longer compacts the v4
format at all** — it ran for 1992 s and left the size byte-for-byte unchanged.

> Note on the 0.2.0 numbers: a *second* fts_vacuum pass on 0.2.0 re-expanded
> 4139 MB → 8279 MB (the known "rewrite grows before truncating, then didn't
> truncate" behaviour — do not run two passes). The fair 0.2.0 compacted size
> is the one-pass **4139 MB**. HEAD's single pass reclaimed nothing.

vs the 1.20-era competitors (same box/PG/corpus): VectorChord 1367 MB (~2.3 min),
pg_textsearch 1831 MB (~4.5 min). HEAD at 15 GB is **~11× VectorChord and ~8×
pg_textsearch** — worse than the 1.20 baseline's 7541 MB gap.

## Ranked latency — before/after + 3-way (ms, median/9, warm, lower better)

### top-10
| query           | 0.2.0 | HEAD  | HEAD vs 0.2.0 | pg_textsearch¹ | VectorChord¹ |
|-----------------|------:|------:|--------------:|---------------:|-------------:|
| rare (slovakia) | 13.4  | 21.8  | **+63% worse**| 3.3            | **1.6**      |
| mid (hungary)   | 11.2  | 18.4  | **+64% worse**| 3.5            | **1.7**      |
| common (year)   | 36.9  | 55.5  | **+50% worse**| 13.0           | **1.7**      |

### top-100
| query         | 0.2.0 | HEAD  | HEAD vs 0.2.0 | pg_textsearch¹ | VectorChord¹ |
|---------------|------:|------:|--------------:|---------------:|-------------:|
| rare          | 30.8  | 39.1  | +27% worse    | –              | –            |
| mid           | 39.7  | 46.7  | +18% worse    | –              | –            |
| common (year) | 67.5  | 86.0  | **+27% worse**| 17.0           | **1.9**      |

### AND top-10 / top-100
| query          | 0.2.0 | HEAD   | HEAD vs 0.2.0 | pg_textsearch¹ | VectorChord¹ |
|----------------|------:|-------:|--------------:|---------------:|-------------:|
| rare&mid  t10  | 20.8  | 55.8   | **+169% worse**| 4.0           | **1.9**      |
| common&mid t10 | 14.3  | 167.0  | **+11.7× worse**| 8.5          | **1.7**      |
| rare&mid  t100 | 45.7  | 83.0   | +82% worse    | –              | –            |
| common&mid t100| 45.7  | 197.0  | **+4.3× worse**| –             | –            |

¹ VectorChord / pg_textsearch columns from `RESULTS_VS_VCHORD_PGTEXTSEARCH.md`
(pg_fts 1.20-era, same box/PG/corpus). Not re-measured this session (P4's AND
regression made the pg_fts side the whole story; rebuilding the Rust engines
was not worth the box time).

P4's "hard top-k early-termination" is the headline claim (common-term top-k
should go **flat**). It did the opposite: common single-term rose 50%, and AND
queries — where P4 changed the traversal most — blew up 4–12×. The impact-tier
directory added per-scan work without pruning.

## Counts — before/after (ms, median/9, warm)

| query          | 0.2.0 fts_count | HEAD fts_count | 0.2.0 count(*) | HEAD count(*) |
|----------------|----------------:|---------------:|---------------:|--------------:|
| rare (10.9k)   | 20.0            | 22.0           | 22.3           | 22.9          |
| common (735k)  | **287.2**       | **399.3**      | **364.7**      | **468.9**     |

P1's decode work was supposed to help common-term count too. It regressed it:
common `fts_count` 287 → 399 ms (+39%), `count(*)` pushdown 365 → 469 ms (+29%).
Rare-term count is a wash.

## Correctness

### Match counts — parity ✓
0.2.0 and HEAD return **identical** match counts:
`year=734881, slovakia=10874, hungary=24095`. (These differ slightly from the
older RESULTS_4WAY baseline — year 735658, slovakia 10889 — which is a
corpus/shard-boundary difference on the first-2.188M cut, not a P1–P4 bug;
HEAD==0.2.0 confirms the analyzer path is unchanged.)

### Ranked top-k — NOT identical, and both are inexact ✗
Single-term top-10 dumps are byte-identical HEAD vs 0.2.0. But the **AND**
query top-10 diverges, and a brute-force ground-truth (seq-scan, exact score
sort) shows **both index-ordered scans drop true top-k documents**:

`slovakia & hungary` top-10 — ground truth (seq scan, exact) vs each engine:

| rank | true docid | true dist | in HEAD top-10? | in 0.2.0 top-10? |
|-----:|-----------:|----------:|:---------------:|:----------------:|
| 1 | 11310605 | 0.443674 | ✓ | **✗ missed** |
| 2 | 20516352 | 0.445293 | **✗ missed** | ✓ |
| 3 | 24418196 | 0.445600 | ✓ | ✓ |
| 4 | 24417640 | 0.445850 | ✓ | ✓ |
| 5 | 6051614  | 0.446523 | **✗ missed** | **✗ missed** |
| 6 | 24425245 | 0.447546 | ✓ | ✓ |
| 7 | 24423383 | 0.447692 | ✓ | ✓ |
| 8 | 10797395 | 0.448073 | **✗ missed** | **✗ missed** |
| 9 | 24420832 | 0.449922 | **✗ missed** | ✓ |
| 10| 24426335 | 0.450282 | ✓ | ✓ |

The exact `<=>` scores agree between engines (11310605=0.443674,
24420832=0.449922, both match `@@@`) — so this is a **retrieval/ordering** bug in
the WAND/MaxScore ranked-index path, not a scoring bug. Even a **single common
term** is inexact: for `year` the index scan returns only 3 of the true top-10
(8100768, 5835670, 7031552) and fills the rest with docs that score *worse*
(22268766 @0.616168, 11345499 @0.616948) while dropping better docs
(20921374 @0.613042, 4091855 @0.613336, 19682699 @0.613440).

- Single-term inexactness is **pre-existing** (identical in HEAD and 0.2.0).
- **P4 changed which docs get dropped on AND queries** (HEAD keeps 11310605,
  0.2.0 keeps 20516352/24420832) — so the series altered ranked output without
  fixing the underlying exactness bug, and is *not* score-identical to 0.2.0 on
  AND queries as the series claimed.

## Build failure (committed HEAD, unpatched)

Committed HEAD `8726525` **fails CREATE INDEX at 2.19M**:
```
ERROR:  invalid memory alloc request size 1073741824
STATEMENT:  CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('english', body));
```
All parallel build workers die the same way. Root cause: P1's new
`bm25_write_doclens()` (pg_fts_am.c) gathers **every posting-pair of the whole
segment** into one flat `pairs` array before sort+dedup; the doubling `cap`
crosses `MaxAllocSize` (1 GB) at this corpus size (regression tests are too
small to hit it). v0.2.0 has no such path.

Minimal fix used to obtain HEAD numbers (build-time only, no format/score
change): swap the two `pairs` allocations to the huge variants —
`palloc → MemoryContextAllocHuge`, `repalloc → repalloc_huge`. A better fix
dedups by docid during gather instead of materialising ~400M pairs. **All HEAD
numbers above are this one-line-patched HEAD; the committed HEAD does not
build at scale.**

## Where pg_fts now stands vs vchord / pg_textsearch
Further behind than the 1.20 baseline on every axis:
- **Size:** 15 GB vs 1367 MB (vchord) / 1831 MB (pg_textsearch) — ~8–11×
  larger, and fts_vacuum no longer reclaims.
- **Ranked latency:** 18–197 ms vs ~1.6–1.9 ms (vchord) / 3.3–17 ms
  (pg_textsearch) — the gap widened.
- **Counts:** still pg_fts's unique capability, but slower than before.

## Verdict
- Did P1 cut size ~40%? **No — +2× after build, and ~3.6× larger than the
  compacted 0.2.0; fts_vacuum stopped reclaiming on v4.**
- Did P2/P3 cut rare/mid latency? **No — rare/mid rose ~60%.**
- Did P4 make common-term top-k flat? **No — common rose 50%; AND queries
  regressed 4–12×.**
- Correctness: **counts parity holds; ranked top-k does not (AND diverges;
  both versions' ranked scan is inexact vs ground truth — report loudly).**
- Build: **committed HEAD cannot build at 2.19M (1 GB palloc overflow in P1).**

**Recommendation:** treat P1–P4 (commits 04f434e, 4b9a88b, 2fd2359, plus the
v4 format) as a regression to revert or rework. The one thing to salvage
independent of the series is the **ranked-exactness bug in the WAND/MaxScore
path**, which predates P1–P4 and silently returns a wrong top-k on common and
AND queries — that should be fixed and gated by a ground-truth parity test.

Measured: EC2 r7i.4xlarge, PostgreSQL 17.10, 2,188,038 Wikipedia articles,
pg_fts v0.2.0 vs HEAD@8726525 (P1 build patched). Instance TERMINATED.
