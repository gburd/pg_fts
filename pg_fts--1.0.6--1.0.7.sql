/* pg_fts 1.0.6 -> 1.0.7
 *
 * Adds to_ftsdoc(tsvector): build an ftsdoc directly from an existing tsvector
 * (no re-analysis of source text) -- the adoption on-ramp for a table that
 * already materializes a tsvector column.  No on-disk format change; no REINDEX.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.0.7'" to load this file. \quit

-- Build an ftsdoc directly from an existing tsvector (no re-analysis of source
-- text): the adoption on-ramp for a table that already materializes a tsvector
-- column.  A tsvector's lexemes are sorted+distinct with ascending positions,
-- exactly ftsdoc's shape; positions are kept iff every lexeme has them.
CREATE FUNCTION to_ftsdoc(tsvector)
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'to_ftsdoc_from_tsvector'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
