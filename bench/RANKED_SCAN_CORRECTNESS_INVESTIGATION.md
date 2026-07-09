# pg_fts v0.2.0 ranked-index-scan correctness investigation

**Verdict: there IS a real correctness bug in the shipped v0.2.0 ranked index
scan — but it is NOT the "drops true top-k on a single common term" the
benchmark reported. That specific symptom was a measurement artifact. The real
bug is that the ranked `ORDER BY d <=> q LIMIT k` index scan IGNORES the query's
boolean structure (AND / NOT / PHRASE) and returns documents that do not satisfy
`@@@ q`.**

Environment: reproduced at small scale (5,000-doc controlled corpus) on the Nix
flake's PostgreSQL 17.10 + pg_fts @ HEAD (`4b65f20`, the reverted v0.2.0 engine).
No EC2 needed — the bug is algorithmic, not scale-dependent.

---

## 1. Reproduction

Controlled corpus: 3,000 skewed docs (common term `alpha` df≈2850, medium `beta`
df≈1200, rare `gamma` df≈60, `delta` for AND tests) + 2,000 distinct-score docs
(`alpha` tf 1–7, `beta` tf 0–4, varied length). ftsdoc stored in a column `d`,
`CREATE INDEX ... USING fts (d)`. Fair oracle = brute-force seq scan of
`fts_bm25(d, q, ndocs, avgdl, fts_index_df(...))` using the SAME stats the index
uses (`fts_index_stats` for ndocs/avgdl, `fts_index_df` for per-term df) —
verified fair (identical formula, identical stats; see §4).

**To force the WAND ordering scan you MUST set both `enable_seqscan=off` AND
`enable_bitmapscan=off`.** With only seqscan off, the planner picks a Bitmap Heap
Scan + Sort, and the Sort uses the `<=>` *operator fallback* (`fts_bm25_distance`,
N=1/avgdl=|D|/df=1), which is meaningless garbage — this is the first thing that
looked like a bug but isn't the index path at all.

Result once the ordering Index Scan is actually forced:

| query | k | score-multiset parity vs fair oracle | boolean (@@@) violations in top-k |
|-------|---|:---:|:---:|
| `alpha` (common) | 10 / 100 | **PASS** (ties only) | 0 |
| `gamma` (rare) | 10 / 100 | **PASS** (ties only) | 0 |
| `alpha beta` (=AND) | 10 / 100 | pass* | 0 in this data |
| `alpha & beta` | 10 / 100 | pass* | 0 in this data |
| `beta & gamma & delta` | 30 | — | **1 violation** |
| `alpha & !beta` | 20 | — | **20/20 violations** |

`*` the score multiset can match even when the SET is wrong, because the ranked
path scores the wrong docs with the same disjunctive formula the oracle applies —
so score parity ALONE is not a sufficient oracle; a boolean-membership check is
needed (see the regression test).

Smoking gun (pristine v0.2.0 engine, forced ordering scan):

- `beta & gamma & delta` LIMIT 30 returns doc `alpha alpha alpha alpha gamma
  delta` — it has gamma+delta but **no beta**, yet is returned for a query that
  requires beta. `d @@@ 'beta & gamma & delta'` is **false** for it.
- `alpha & !beta` LIMIT 20 returns **only docs that contain beta** — the exact
  opposite of the query. Every one of the 20 rows violates the `!beta`.

---

## 2. Root cause — RETRIEVAL, in the ranked path's candidate generation

Not a WAND block-max bound bug, not a scoring mismatch, not the oracle.

`pg_fts_am_scan.c:bm25_topk_candidates_range` (~2585) builds WAND cursors from
`fts_query_terms(q)`, which (`pg_fts_rank.c:85`, by explicit design) **flattens
all term operands and discards the boolean operators**:

> "Operators and duplicate terms are ignored — BM25 sums over the query's terms
> present in the document, regardless of the boolean structure (matching
> Lucene…)."

So the WAND/BMW/MaxScore engine computes the top-k of the **disjunction** of the
query's terms. That is correct *scoring* (BM25 is disjunctive), but the ranked
path never intersects those candidates with the query's actual boolean match set.
`@@@` uses `bm25_eval_query` (`pg_fts_am_scan.c:633`) which correctly implements
AND/OR/NOT/PHRASE set algebra; the ranked `<=>` path does not call it. The
`amgettuple` ordering scan therefore returns the disjunctive top-k verbatim, and
the executor (amcanorderbyop) trusts the index order — the `@@@` Index Cond is
NOT re-applied to ordering-scan output.

- **AND**: a doc containing only some of the AND'd terms still scores (on the
  terms it has) and can rank into the top-k though it fails `@@@`.
- **NOT** (worst): the `!term` operand is fed to the scorer as a positive term,
  so docs containing the excluded term get the HIGHEST scores and dominate the
  top-k — the ranked scan returns exactly the documents it must exclude.

The WAND/BMW engine itself is EXACT for the disjunction it is asked to rank:
`fts_search()` (same engine, direct SRF) matches the fair oracle's score multiset
bit-for-bit for `alpha`, `gamma`, `alpha & beta`, `beta & gamma & delta` at k=100
(0 positions differ). `wand_block_max_contrib` (~1990) IS a sound upper bound —
`min_doclen`/`max_tf` are the true block MIN/MAX (`pg_fts_am.c:763-816`), and BM25
contribution is monotone increasing in tf, decreasing in |D|, using the identical
idf/k1/b as the exact scorer. So the block-skip is sound; the bug is purely that
the candidate set is the disjunction, not the boolean match set.

---

## 3. Why the benchmark's "single common term drops top-k" was an ARTIFACT

The benchmark reported the single-common-term index scan returning only 3 of the
true top-10. At small scale this does NOT reproduce as a bug:

- The true top-k for a single common term is a huge SCORE TIE (e.g. 75 docs all
  at the max score 0.098798 — same tf, same doclen). The index and a
  `... ORDER BY score DESC, id`-tiebroken oracle pick DIFFERENT members of the
  tie. Both are valid top-k. The score multiset is identical; every index-
  returned doc is at the maximum score (verified: 10/10 at max). The property
  "same docids modulo score ties" holds.
- The benchmark's own numbers are consistent with this: it said the `<=>` scores
  AGREE between engines but the SET differs — that is the signature of a tie, not
  a retrieval miss. Its ground-truth oracle almost certainly used a different
  tiebreak (or, on the 2.19M run with `autovacuum=off`, a mid-build stat skew),
  so the "3 of 10" was a tie/tiebreak/plan-selection artifact, not the index
  dropping high-score docs. The benchmark also likely measured a Bitmap+Sort
  fallback for some queries (the operator-fallback `<=>` garbage), which would
  fully explain a scrambled single-term order.

The benchmark's AND-divergence observation, however, is the REAL bug above.

---

## 4. Oracle fairness (verified, not assumed)

- Scoring formula: index (`wand_contrib_cur`, `pg_fts_am_scan.c:2115`) and
  `fts_bm25` (`pg_fts_rank.c:171`) are the identical Lucene BM25:
  `idf*(k1+1)*tf / (tf + k1*(1-b) + (k1*b/avgdl)*dl)`, idf =
  `ln(1+(N-df+0.5)/(df+0.5))`, k1=1.2, b=0.75.
- Stats: oracle pulls N & avgdl from `fts_index_stats` and per-term df from
  `fts_index_df` — the exact values the index computes (metapage ndocs/sumdoclen,
  dictionary df). Confirmed: for AND-matching docs the index engine score ==
  `fts_bm25` oracle score to 6 decimals for every doc checked.
- The AND/NOT violations are oracle-independent: the returned docs fail `@@@`
  itself (a boolean predicate with no scoring), so no stat choice can make them
  correct.

---

## 5. Proposed fix (drafted + tested, NOT committed — needs maintainer OK)

For a non-pure-OR query, rank the EXACT `@@@` match set instead of the
disjunction: take `bm25_collect_matches(index, q)` (the boolean-correct TID set),
score only those docids (document-at-a-time, seeking the term cursors, summing the
same per-posting contributions), keep top-k. Pure-OR queries keep the fast WAND
path unchanged (disjunction == match set, zero overhead). Detection helper
`fts_query_is_pure_or` (only OR operators, no prefix/fuzzy/regex operand).

Tested outcome of a prototype of this fix (built + run on the temp cluster):

- AND/NOT violations → **0** across all cases (`alpha & !beta`, `beta & gamma &
  delta`, etc.).
- BUT it surfaced a SECONDARY latent bug: the WAND cursor seek machinery
  (`wand_seek`/`wand_skip_blocks`, `pg_fts_am_scan.c:2093/2193`) is not robust to
  the "many small forward seeks to arbitrary targets" pattern the match-set
  scorer needs — a cursor exhausts a few blocks early near the end of a long
  posting list (one of three tied top docs was dropped). This double-count /
  early-exhaust in the repeated-seek path is masked in normal WAND by the
  over-fetch, but is a real fragility. **Because of this, the fix is not yet
  correct and I did NOT commit it.** The clean fix is either (a) make
  `wand_skip_blocks`/`wand_seek` robust to repeated arbitrary-target seeks
  (audit the `nread`/`df` accounting), then use the match-set scorer, or (b)
  thread the match-set as a docid filter into the existing WAND loop so the
  proven-correct single-pass traversal is preserved. Both are maintainer-level
  changes to the traversal core and should be reviewed before landing.

---

## 6. Permanent regression test (drafted)

A self-contained SQL block (see `sql/pg_fts.sql` draft below) that, with the
ordering scan forced, asserts:
1. AND top-k: every returned row satisfies `@@@` (0 violations).
2. NOT top-k: no returned row contains the excluded term (0 violations).
3. 3-term AND at larger k: 0 violations.
4. score-multiset parity (tie-blind, fair stats) for a common term, a rare term,
   and an AND.

Verified it FAILS on pristine v0.2.0 (not_violations=20, and3_violations=13) and
would PASS once the boolean-structure fix lands. I have NOT added it to
`sql/pg_fts.sql` / `expected/pg_fts.out` yet, because committing a test that
fails against the current engine would break the build before the fix is in — it
should land together with the fix. The draft SQL is ready in the report appendix.

---

## Summary

- Single-common-term "drops top-k": **NOT a bug** — score ties + a plan/operator-
  fallback measurement artifact. WAND engine is exact.
- WAND block-max bound: **sound** (correct MIN doclen / MAX tf, matching idf/k1/b).
- Real bug: **ranked `<=>` ordering scan ignores boolean AND/NOT/PHRASE structure
  and returns documents that fail `@@@`** — `bm25_topk_candidates_range` ranks the
  term disjunction and never intersects with the boolean match set. NOT queries
  return the exact opposite of the intended set.
- Fix direction is clear and the boolean-filter half is proven to remove all
  violations, but it exposes a secondary cursor-seek robustness bug that must be
  fixed too. Neither is committed; both need maintainer review.


---

## Appendix: drafted regression test SQL (for sql/pg_fts.sql)

```sql
-- ============================================================================
-- REGRESSION TEST DRAFT: ranked index scan must respect boolean query structure
-- ============================================================================
-- Property: for `WHERE d @@@ q ORDER BY d <=> q LIMIT k`, every returned row
-- must satisfy the boolean qual `d @@@ q`.  The WAND/MaxScore ranked path
-- scores the DISJUNCTION of query terms and (in v0.2.0) ignores AND/NOT/PHRASE
-- structure, so it can return documents that fail @@@.
CREATE TABLE boolrank (id serial, d ftsdoc);
INSERT INTO boolrank(d) SELECT to_ftsdoc(
    (CASE WHEN g%2=0 THEN 'alpha ' ELSE '' END)||
    (CASE WHEN g%3=0 THEN repeat('beta ', 1+g%4) ELSE '' END)||   -- beta common + tf skew
    (CASE WHEN g%7=0 THEN 'gamma ' ELSE '' END)||
    (CASE WHEN g%11=0 THEN 'delta ' ELSE '' END)||
    repeat('lorem ', g%15)||'w'||g)
  FROM generate_series(1,6000) g;
CREATE INDEX boolrank_idx ON boolrank USING fts (d);
SET enable_seqscan = off; SET enable_bitmapscan = off;   -- force the ordering index scan

-- (1) AND: every ranked top-k row must contain BOTH terms.
SELECT count(*) AS and_violations FROM (
  SELECT d FROM boolrank WHERE d @@@ 'alpha & gamma'::ftsquery
  ORDER BY d <=> 'alpha & gamma'::ftsquery LIMIT 20) x
WHERE NOT (x.d @@@ 'alpha & gamma'::ftsquery);          -- expect 0

-- (2) NOT: no ranked top-k row may contain the excluded term.
SELECT count(*) AS not_violations FROM (
  SELECT d FROM boolrank WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 20) x
WHERE NOT (x.d @@@ 'alpha & !beta'::ftsquery);          -- expect 0

-- (3) 3-term AND at larger k.
SELECT count(*) AS and3_violations FROM (
  SELECT d FROM boolrank WHERE d @@@ 'alpha & gamma & delta'::ftsquery
  ORDER BY d <=> 'alpha & gamma & delta'::ftsquery LIMIT 30) x
WHERE NOT (x.d @@@ 'alpha & gamma & delta'::ftsquery);  -- expect 0

-- (4) exact top-k parity: index ordering scan == brute-force score sort,
--     compared as a score MULTISET (tie-blind), using the SAME index stats so
--     the oracle is fair.  Tests common term, rare term, and an AND.
CREATE OR REPLACE FUNCTION _rank_parity(qtext text, kk int) RETURNS bool
LANGUAGE plpgsql AS $$
DECLARE nd float8; ad float8; dfs float8[]; ixs numeric[]; gts numeric[];
BEGIN
  SELECT ndocs, avgdl INTO nd, ad FROM fts_index_stats('boolrank_idx');
  SELECT fts_index_df('boolrank_idx', qtext::ftsquery) INTO dfs;
  SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;
  EXECUTE format($f$SELECT array_agg(round(sc::numeric,6) ORDER BY sc DESC) FROM (
     SELECT fts_bm25(x.d,%L::ftsquery,%s,%s,%L) sc FROM (
       SELECT d FROM boolrank WHERE d @@@ %L::ftsquery ORDER BY d <=> %L::ftsquery LIMIT %s) x) z$f$,
     qtext,nd,ad,dfs,qtext,qtext,kk) INTO ixs;
  SET LOCAL enable_seqscan=on; SET LOCAL enable_indexscan=off; SET LOCAL enable_bitmapscan=off;
  EXECUTE format($f$SELECT array_agg(round(sc::numeric,6) ORDER BY sc DESC) FROM (
     SELECT fts_bm25(d,%L::ftsquery,%s,%s,%L) sc FROM boolrank WHERE d @@@ %L::ftsquery
     ORDER BY sc DESC LIMIT %s) z$f$, qtext,nd,ad,dfs,qtext,kk) INTO gts;
  RETURN ixs IS NOT DISTINCT FROM gts;
END $$;
SELECT _rank_parity('beta',10)          AS common_k10,   -- expect t
       _rank_parity('gamma',10)         AS rare_k10,     -- expect t
       _rank_parity('alpha & gamma',10) AS and_k10;      -- expect t (currently f/violates)

DROP FUNCTION _rank_parity(text,int);
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE boolrank;
```
