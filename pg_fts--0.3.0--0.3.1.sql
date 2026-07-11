/* pg_fts--0.3.0--0.3.1.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.3.1'" to load this file. \quit

-- 0.3.1 is an additive feature release: lexical anomaly detection.  No on-disk
-- format change (this is read-only over the existing index) and no REINDEX is
-- required.  It adds one set-returning function that surfaces the most
-- anomalous documents -- those containing globally RARE terms -- by walking the
-- low-df tail of the term dictionary; common terms are skipped before any
-- posting is decoded, so it is cheap and not a full-corpus scan.
CREATE FUNCTION fts_anomalous_docs(index regclass, k int DEFAULT 100,
                                   max_df int DEFAULT NULL,
                                   OUT ctid tid, OUT score float8,
                                   OUT rarest_term text, OUT min_df int)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'fts_anomalous_docs'
LANGUAGE C PARALLEL SAFE;
