# NOTE: ranked `<=>` top-k recall — distinct-score investigation (v0.2.2)

**Verdict: NO recall bug in the WAND/MaxScore ranked scan.** On a *flushed*
index the ranked `ORDER BY d <=> q LIMIT k` scan returns the EXACT top-k —
bit-for-bit equal to a fair brute-force BM25 oracle — for single common, single
rare, 2-term OR, 2-term AND, and 4-term (MaxScore) queries, at k = 1, 5, 10, 50,
100, 200, on both single- and multi-segment indexes, verified with **provably
distinct scores (zero ties)**. The RESULTS_P1_P4 "index returns only 3 of the
true top-10" claim does **NOT** reproduce once scores are made distinct and the
plan is forced.

The one *apparent* miss I could produce (17 of the true top-100 "dropped" on a
28-segment index) is a **measurement artifact of the documented pending-list
limitation**: `<=>` / `fts_search` rank *flushed segments only*, never the
unflushed pending list (`CAPABILITIES.md:36,127-128`;
`pg_fts_am_scan.c` ranked engine builds cursors from `meta.segs` only). The
seq-scan oracle sees pending rows; the ranked path does not until a `VACUUM`
flush. Comparing the two while rows sit in pending is unfair. A single `VACUUM`
makes the miss vanish (nmiss 17 → 0, srf coverage 139/720 → 720/720). This is
distinct from the earlier reports' confounders (score ties + the `<=>`
operator-fallback) and is the *only* thing that survived the distinct-score
test — and it is a known, documented limitation, not a WAND retrieval bug.

Environment: Nix flake `checks.x86_64-linux.installcheck-pg17`, PostgreSQL
17.10, pg_fts @ HEAD (`6147fb8`, tag **v0.2.2**). No EC2 needed — every effect is
algorithmic and reproduces at ≤5k docs. READ-ONLY: no engine code changed; the
probes were appended to `sql/pg_fts.sql`, run, read from `nix log`
regression.diffs, and the test files restored.

---

## 1. Method — distinct-score corpus that eliminates every confounder

The two prior notes disagreed because two confounders were in play:
1. **Score ties** — a single common term is a huge score tie; index and oracle
   pick different valid tie members, so the *set* differs while the *multiset of
   scores* matches. (RANKED_SCAN note.)
2. **Operator fallback / wrong plan** — `<=>` in a SELECT list, or a Bitmap+Sort
   plan, evaluates `fts_bm25_distance` (N=1/df=1) instead of driving the AM
   ordering scan. (RANKED_SCAN note.)

To kill both, every corpus below gives each matching doc a **globally-unique
term frequency**, so BM25 scores are strictly distinct (a `GROUP BY score HAVING
count(*)>1` tie counter `ntie` = 0 in every reported row). With distinct scores,
**any difference in the returned SET is a real recall miss** — no tie can excuse
it. The plan is forced to the ordering Index Scan and asserted by EXPLAIN.

- Config: `to_ftsdoc(text)` (the 'simple' analyzer — no stemming/stopwords).
- Stored `ftsdoc` column `d`; `CREATE INDEX ... USING fts (d)`.
- Fair oracle: `fts_bm25(d, q, s.ndocs, s.avgdl, fts_index_df(idx,q))` with
  `s = fts_index_stats(idx)` — the *identical* N/avgdl/df the index uses (idf,
  k1=1.2, b=0.75, and the Lucene BM25 formula are byte-identical between
  `wand_contrib_cur` `pg_fts_am_scan.c` and `fts_bm25_score` `pg_fts_rank.c`;
  verified by reading both).
- Index result: `SET enable_seqscan=off; SET enable_bitmapscan=off;` then
  `SELECT id ... WHERE d @@@ q ORDER BY d <=> q LIMIT k`.

### EXPLAIN-confirmed plan (asserted in every probe)

```
 Limit
   ->  Index Scan using rr_idx on rr
         Index Cond: (d @@@ 'alpha'::ftsquery)
         Order By: (d <=> 'alpha'::ftsquery)
```

Not a Seq Scan + Sort, not a Bitmap Heap Scan + Sort-on-fallback. This is the
`amgettuple` ordering scan (`bm25_gettuple` → `bm25_topk_visible` →
`bm25_topk_candidates_range` → `fts_search_wand`). For the 4-term case the
Index Cond / Order By show the AND'd query, same node shape. The `fts_search()`
SRF (which bypasses the planner) was tested directly too.

---

## 2. Result — index top-k == oracle top-k, distinct scores, flushed index

`nmiss` = index-returned ids absent from the oracle top-k (a real recall miss iff
`ntie=0`). `ntie` = score ties in the full match set (must be 0). All rows below
have **ntie=0** (genuinely distinct scores).

### Single-segment (probe v3, 1540/300/12-match corpora)

| query | shape | k sweep | nmiss | ntie |
|-------|-------|---------|:-----:|:----:|
| `alpha` | common (1540) | 1,5,10,50,100 | **0** | 0 |
| `gamma` | rare (12) | 1,10 | **0** | 0 |
| `alpha \| beta` | 2-term OR (1540) | 10,100 | **0** | 0 |
| `alpha & beta` | 2-term AND (300) | 5,10,50 | **0** | 0 |

Adversarial layout (highest-tf docs at the END of the posting list, so an
unsound block-max bound would skip them): still **nmiss=0**.

### Flushed multi-segment (probe v12; 4 VACUUM'd batches → nseg=4; varied doclen)

| query | nseg | nmatch | srf coverage | k | nmiss | ntie | realbug |
|-------|:----:|:------:|:------------:|:-:|:-----:|:----:|:-------:|
| `alpha` | 4 | 280 | 280/280 | 50 | **0** | 0 | f |
| `alpha` | 4 | 280 | 280/280 | 100 | **0** | 0 | f |
| `alpha` | 4 | 280 | 280/280 | 200 | **0** | 0 | f |

`srf coverage` = `fts_search(...,100000)` returns **all** matches once flushed.

### 4-term MaxScore path (probe v4; ≥4 terms → `fts_search_maxscore`)

| query | shape | k | nmiss | ntie |
|-------|-------|:-:|:-----:|:----:|
| `alpha & beta & delta & epsilon` | AND, 243 matches | 10,50 | **0** | 0 |
| `alpha \| beta \| delta \| epsilon` | OR, 910 matches | 10,50 | **0** | 0 |

The `>=4-term MaxScore` path and the `<4-term BMW` path both return the exact
top-k with distinct scores.

### fts_search() SRF direct (bypasses planner)

`srf_alpha_top10` vs fair oracle top-10 on the single-segment distinct corpus:
`srf_miss = 0`.

**Conclusion of §2:** with distinct scores, a forced ordering scan, and a
flushed index, the WAND (BMW <4 terms) and MaxScore (≥4 terms) engines are
**exact** at every k and every query shape tested. The block-max bound
(`wand_block_max_contrib`, uses true block `max_tf` / `min_doclen`) is sound:
the adversarial "best docs last" layout never lost a doc.

---

## 3. The ONE apparent miss — and why it is the pending-list artifact

The only way I reproduced a set difference with distinct scores:

Corpus: 24 un-vacuumed INSERT batches, `alpha` tf globally unique per doc,
`s%3==0` docs also get `beta` tokens (→ longer doc, lower alpha score), scattered
so traversal order ≠ score order. `ANALYZE` only (no VACUUM).

| phase | nseg | nmatch | srf coverage | ntie | nmiss@k100 | extra_max_true | missing_min_true |
|-------|:----:|:------:|:------------:|:----:|:----------:|:--------------:|:----------------:|
| **before VACUUM** | 28 | 720 | **139/720** | 0 | **17** | 3.610569 | 3.610607 |
| **after VACUUM**  | 1  | 720 | **720/720** | 0 | **0**  | — | — |

Before the flush, `fts_search(..., 100000)` returns only **139 of 720** matches —
the other 581 sit in the **pending list**, which the ranked engine never scans.
The 17 "missed" true-top-100 docs are pending rows; the seq-scan oracle counts
them, the ranked path cannot rank them. `missing_min_true (3.610607) >
extra_max_true (3.610569)` looked like a genuine recall loss — but it is purely
that the ranked candidate universe was 139, not 720. **A single `VACUUM` (which
folds pending into a ranked segment) drives nmiss to 0 and srf coverage to
720/720.**

Isolation (probe v8/v10/v11):
- **Deletes/tombstones alone (no beta): nmiss=0.** Tombstones are not the cause.
- **Under-collection deficit is ≈ one batch's worth, not per-segment:**
  2 batches→275/600, 3→575/900, 5→1175/1500, 10→1775/2000 — a *constant* ~one-
  batch (pending) shortfall, the signature of "last inserts still in pending,"
  not a WAND traversal defect.
- **Single-segment, varied doclen: srf 720/720, nmiss=0** — no under-collection
  when everything is in one segment.
- **Flushed multi-segment (nseg=4): srf 280/280, nmiss=0** — no under-collection
  once pending is flushed, even across multiple segments.

This is the documented limitation: **"`<=>` / `fts_search` ranking does not cover
unflushed pending docs until a flush"** (`CAPABILITIES.md:36,127-128`; the ranked
engine `bm25_topk_candidates_range` builds cursors only over `meta.segs`, never
the pending buffer). `@@@` and `fts_count` DO see pending docs; ranking does not.
It is a *coverage* limitation of the ranked path over freshly-inserted rows, not
an *inexactness* of the WAND/MaxScore algorithm over what it does rank.

---

## 4. Reconciling the two prior findings

- **RESULTS_P1_P4 "index returns only 3 of the true top-10 for `year`"**:
  **does NOT reproduce.** On a distinct-score common term the ranked scan
  matches the oracle top-10/50/100 exactly (nmiss=0). The P1-P4 symptom is fully
  explained by the confounders the RANKED_SCAN note identified — a single-common-
  term top-k is a large **score tie** (index and oracle pick different valid tie
  members; scores agree, set differs), compounded by the `<=>`-in-SELECT
  **operator fallback** / Bitmap+Sort plan unless BOTH `enable_seqscan=off` and
  `enable_bitmapscan=off` force the AM ordering scan. On the 2.19M P1-P4 run
  `autovacuum=off` also left a large pending list mid-build, which (per §3) makes
  the ranked path under-cover vs a seq-scan oracle — a third contributor to the
  same apparent "miss." **Artifact confirmed, on all three counts.**

- **RANKED_SCAN_CORRECTNESS_INVESTIGATION "WAND engine is exact for the
  disjunction; real bug is boolean structure ignored (AND/NOT/PHRASE)"**:
  The boolean-structure bug it found **has been FIXED in v0.2.2** — the ranked
  path now computes the exact `@@@` match set (`bm25_collect_matches`) and passes
  it as a `DocidFilter` gate on heap admission for any non-pure-OR query
  (`pg_fts_am_scan.c` `bm25_topk_candidates_range`, `docid_admitted`,
  `fts_search_bmw`/`fts_search_maxscore`). My AND / 4-term-AND probes returned 0
  `@@@` violations and matched the oracle set exactly. That note's core claim
  ("the WAND/BMW engine is exact — matches the fair oracle bit-for-bit") is
  **confirmed and now extended to distinct scores and multiple k**, and its
  "single-common-term is ties+artifact" conclusion is **confirmed**.

---

## 5. Root-cause status (no bug to fix in the ranked scorer)

- **Retrieval (WAND/BMW/MaxScore over flushed segments): exact.** Block-max
  bound sound (`wand_block_max_contrib` uses true block `max_tf`/`min_doclen`);
  adaptive-k over-fetch (`wantk = k*4`, grow ×4 to `BM25_MAX_ORDERK`) never
  under-collected the top-k in any distinct-score flushed test; the `DocidFilter`
  boolean gate correctly restricts AND/NOT/PHRASE to the `@@@` set; the
  `>=4-term` MaxScore path agrees with the `<4-term` BMW path and the oracle.
- **Scoring: exact.** `wand_contrib_cur` == `fts_bm25` (same idf/k1/b/avgdl,
  same formula); with distinct scores the ordering is unambiguous and matches.
- **The pending-list ranking gap is a documented coverage limitation, not a
  recall bug in the scorer.** If desired, it is a *product* decision (make the
  ranked path also rank pending docs, or auto-flush) — see §6 — but it is not the
  "silently drops true top-k" defect the P1-P4 note alleged, and it does not
  affect a flushed/steady-state index.

**No `file:line` root-cause for a WAND recall bug exists, because there is no
WAND recall bug.** The only actionable item is the (already-documented) pending
coverage gap.

---

## 6. Optional follow-up (product, not a correctness fix)

If ranking freshly-inserted-but-unflushed rows matters for a workload:
- **Cheapest:** document louder / surface in the ranked-scan path that a
  `VACUUM` (or `fts_merge()`) is required for pending rows to enter `<=>`
  results; the count/`@@@` paths already include them.
- **Fuller:** have `bm25_topk_candidates_range` also open a cursor over the
  pending buffer (as `bm25_collect_matches` already does for `@@@`) and merge its
  scored docs into the WAND heap. This is a feature, gated behind the same
  tombstone/visibility handling the segment cursors use — not a regression fix.

---

## 7. Drafted ground-truth parity regression test (deterministic, distinct scores)

Distinct scores make this **deterministic** (no tie tiebreak dependence). It
asserts the ranked ordering scan == the fair BM25 oracle as a *set* at multiple
k, on both a single-segment and a **flushed** multi-segment index, for common /
rare / OR / AND / 4-term shapes. It PASSES on v0.2.2. (Not committed — provided
for the maintainer to add to `sql/pg_fts.sql` + `expected/pg_fts.out`.)

```sql
-- ranked <=> ordering scan must equal the fair brute-force BM25 top-k SET.
-- Distinct scores (unique tf per doc) => deterministic, no tie ambiguity.
-- Index MUST be flushed (VACUUM) so the ranked path covers all docs; pending
-- docs are intentionally not ranked (CAPABILITIES.md), so a flush is part of
-- the contract this test checks.
CREATE TABLE rankparity (id int, d ftsdoc);
-- unique alpha tf per doc (1..600) -> strictly distinct single-term scores;
-- every 4th doc also carries beta/delta/epsilon for OR/AND/4-term coverage.
INSERT INTO rankparity(id, d)
SELECT g, to_ftsdoc(repeat('alpha ', g) ||
       (CASE WHEN g % 4 = 0 THEN 'beta delta epsilon ' ELSE '' END))
FROM generate_series(1, 600) g;
-- rare term, distinct tf
INSERT INTO rankparity(id, d)
SELECT 10000+g, to_ftsdoc(repeat('gamma ', g)) FROM generate_series(1, 12) g;
CREATE INDEX rankparity_idx ON rankparity USING fts (d);
VACUUM rankparity;   -- flush: ranked path covers all docs
ANALYZE rankparity;

-- returns the number of index-top-k rows NOT in the fair-oracle top-k (expect 0)
CREATE OR REPLACE FUNCTION _rank_miss(qtext text, kk int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE nd float8; ad float8; dfs float8[]; ntie int; nmiss int;
BEGIN
  SELECT ndocs, avgdl INTO nd, ad FROM fts_index_stats('rankparity_idx');
  SELECT fts_index_df('rankparity_idx', qtext::ftsquery) INTO dfs;
  -- distinct-score guard: the test is only meaningful with 0 ties
  EXECUTE format($f$SELECT count(*) FROM (
     SELECT round(fts_bm25(d,%L::ftsquery,%s,%s,%L)::numeric,12) sc
     FROM rankparity WHERE d @@@ %L::ftsquery) z GROUP BY sc HAVING count(*)>1$f$,
     qtext,nd,ad,dfs,qtext) INTO ntie;
  IF COALESCE(ntie,0) <> 0 THEN
    RAISE EXCEPTION 'rank parity test corpus has % score ties for %', ntie, qtext;
  END IF;
  SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
  EXECUTE format($f$
    SELECT count(*) FROM (
      SELECT id FROM rankparity WHERE d @@@ %L::ftsquery
      ORDER BY d <=> %L::ftsquery LIMIT %s) ix
    WHERE ix.id NOT IN (
      SELECT id FROM rankparity WHERE d @@@ %L::ftsquery
      ORDER BY fts_bm25(d,%L::ftsquery,%s,%s,%L) DESC, id LIMIT %s)$f$,
    qtext, qtext, kk, qtext, qtext, nd, ad, dfs, kk) INTO nmiss;
  RETURN nmiss;
END $$;

SELECT _rank_miss('alpha',1)                          AS common_k1,   -- 0
       _rank_miss('alpha',10)                         AS common_k10,  -- 0
       _rank_miss('alpha',50)                         AS common_k50,  -- 0
       _rank_miss('alpha',100)                        AS common_k100, -- 0
       _rank_miss('gamma',10)                         AS rare_k10,    -- 0
       _rank_miss('alpha | beta',50)                  AS or_k50,      -- 0
       _rank_miss('alpha & beta',50)                  AS and_k50,     -- 0
       _rank_miss('alpha & beta & delta & epsilon',50) AS and4_k50;   -- 0 (MaxScore)

-- boolean-structure gate (v0.2.2 DocidFilter): AND/NOT top-k rows must satisfy @@@
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT count(*) AS and_bool_violations FROM (
  SELECT d FROM rankparity WHERE d @@@ 'alpha & beta'::ftsquery
  ORDER BY d <=> 'alpha & beta'::ftsquery LIMIT 50) x
WHERE NOT (x.d @@@ 'alpha & beta'::ftsquery);          -- 0
SELECT count(*) AS not_bool_violations FROM (
  SELECT d FROM rankparity WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 50) x
WHERE NOT (x.d @@@ 'alpha & !beta'::ftsquery);         -- 0

RESET enable_seqscan; RESET enable_bitmapscan;
DROP FUNCTION _rank_miss(text,int);
DROP TABLE rankparity;
```

Expected output: all eight `_rank_miss` columns `0`, both `*_violations` `0`.

---

## 8. Evidence trail (all via `nix build .#checks.x86_64-linux.installcheck-pg17`)

| probe | corpus | key result |
|-------|--------|------------|
| v1 | single-seg distinct, common/rare/OR/AND, k=1..100 | ntie=0, nmiss=0 everywhere; plan = Index Scan Order By |
| v2 | 4000-doc, tf CYCLED (`g%97`) | ntie>0 → nmiss>0 (TIE artifact, correctly excluded) |
| v3 | globally-unique tf, adversarial, single-seg | ntie=0, nmiss=0 at k=1..100; smoking-gun query 0 rows |
| v4 | multi-batch, 4-term MaxScore, distinct | ntie=0, nmiss=0 (BMW and MaxScore both exact) |
| v5/v6/v10/v11 | un-vacuumed multi-batch | srf under-covers by ≈one pending batch (constant deficit) |
| v8 | isolate beta-doclen vs deletes | deletes→nmiss0; beta+unflushed→apparent nmiss17 |
| v9 | fts_search coverage, wantk 400/700/2000 | srf capped at 139/720 → pending unranked, k-independent |
| v12 | flushed multi-seg (nseg=4), varied doclen | srf 280/280, nmiss=0 at k=50/100/200 |
| v13 | exact CASE-A corpus, before/after VACUUM | before: nseg28 srf139 nmiss17; after: srf720 nmiss0 |

Skepticism applied in both directions: no bug was declared on a tie (v2's
nmiss>0 was traced to ntie>0 and discarded); "exact" was not declared until a
distinct-score test passed at multiple k on both single- and multi-segment
flushed indexes; and the one distinct-score set difference (v13 before-VACUUM)
was root-caused to the documented pending coverage limitation, not to WAND.

Test files (`sql/pg_fts.sql`, `expected/pg_fts.out`) restored to the v0.2.2 HEAD
after the investigation (verified `git diff` clean). No engine code changed.
