/*
 * bench/anomaly.sql -- lexical anomaly detection harness.
 *
 * Times fts_anomalous_docs(idx, 100) on a large corpus of common boilerplate
 * with a handful of injected globally-rare tokens, showing that the rare-token
 * docs are surfaced in MILLISECONDS -- because only the LOW-df tail of the term
 * dictionary is walked (common, high-df terms are skipped before any posting is
 * decoded), so it is not a full-corpus scan.  This is design #1 from
 * bench/NOTE_ANOMALY_DETECTION.md ("cheapest, no format change").
 *
 * Usage:
 *   psql -f bench/anomaly.sql
 * Self-contained: it builds its own corpus (override N with -v n=...).
 *
 * Expected behavior:
 *   - The query returns the injected zqxjkrare* docs (min_df = 1, the highest
 *     idf/score), and NOT the common-only docs.
 *   - Latency is a few milliseconds even at 1M docs: the walk cost scales with
 *     the size of the rare tail (terms with df <= max_df), not the corpus.
 *   - Contrast: raising max_df to admit common terms (e.g. df ~ N) forces their
 *     long posting lists to decode -- that IS a large scan and is the wrong way
 *     to use this function; the point is the low-df tail.
 */

\timing on
\set n 1000000

CREATE EXTENSION IF NOT EXISTS pg_fts;

DROP TABLE IF EXISTS anom_bench;
CREATE TABLE anom_bench (id serial, d ftsdoc);

-- N docs of common boilerplate: long, high-df posting lists (the "normal" mass)
INSERT INTO anom_bench (d)
SELECT to_ftsdoc('the quick brown fox jumps over the lazy dog common ordinary text')
FROM generate_series(1, :n);

-- a few docs carrying a globally-unique rare token (the anomalies)
INSERT INTO anom_bench (d) VALUES
  (to_ftsdoc('the quick brown fox zqxjkrare001')),
  (to_ftsdoc('lazy dog common zqxjkrare002')),
  (to_ftsdoc('ordinary text zqxjkrare003')),
  (to_ftsdoc('quick fox jumps zqxjkrare004')),
  (to_ftsdoc('brown dog lazy zqxjkrare005'));

CREATE INDEX anom_bench_bm25 ON anom_bench USING fts (d);
ANALYZE anom_bench;

SELECT ndocs, nterms FROM fts_index_stats('anom_bench_bm25');

\echo === fts_anomalous_docs(idx, 100): the rare-token docs, ranked by rarity ===
-- Times the low-df-tail walk.  On a corpus this size the common terms have
-- df ~ N and are skipped before decode; only the df=1 rare tokens are decoded.
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT b.id, r.rarest_term, r.min_df, r.score
FROM fts_anomalous_docs('anom_bench_bm25', 100) r
JOIN anom_bench b ON b.ctid = r.ctid
ORDER BY r.score DESC, b.id;

\echo === the result set (should be exactly the 5 injected anomalies) ===
SELECT b.id, r.rarest_term, r.min_df, round(r.score::numeric, 3) AS score
FROM fts_anomalous_docs('anom_bench_bm25', 100) r
JOIN anom_bench b ON b.ctid = r.ctid
ORDER BY r.score DESC, b.id;

\echo === warm-cache latency (raw SRF; timing reports the walk cost) ===
SELECT count(*) FROM fts_anomalous_docs('anom_bench_bm25', 100);
SELECT count(*) FROM fts_anomalous_docs('anom_bench_bm25', 100);

DROP TABLE anom_bench;
