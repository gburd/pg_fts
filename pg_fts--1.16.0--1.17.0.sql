/* pg_fts 1.16.0 -> 1.17.0
 *
 * Adds fts_index_segments(regclass): per-segment document, tombstone and term
 * counts.  Everything else is in C: the corpus document count and length total
 * now follow deletions (CHANGELOG 1.17.0), PostgreSQL 19 support, sparsemap
 * 5.8.5.  No on-disk index format change (BM25_VERSION unchanged); no REINDEX.
 */

\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.17.0'" to load this file. \quit

CREATE FUNCTION fts_index_segments(regclass,
                                   OUT segment integer, OUT ndocs bigint,
                                   OUT ndeleted bigint, OUT nterms bigint,
                                   OUT doclen_sidecar boolean,
                                   OUT tombstone_bytes bigint)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'fts_index_segments'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;
