/* pg_fts 1.3.2 -> 1.4.0
 *
 * 1.4.0 adds field-targeted (weight-zone) search: to_ftsdoc(config,text,weight),
 * setftsweight(ftsdoc,weight), ftsdoc || ftsdoc, and the query syntax term:A
 * (tsvector-style A/B/C/D field zones).  Weight labels live in the ftsdoc VALUE
 * (the top 2 bits of each token position); the on-disk INDEX format is UNCHANGED
 * (still v3) and field-restricted queries are answered via the heap recheck, so
 * NO REINDEX is required -- existing indexes keep working and queries without a
 * :label behave exactly as before.  To get field provenance, rebuild a table's
 * ftsdoc from labelled `to_ftsdoc(...,weight) || ...` documents (opt-in).
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.4.0'" to load this file. \quit

CREATE FUNCTION to_ftsdoc(regconfig, text, "char")
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'to_ftsdoc_byid_weight'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION setftsweight(ftsdoc, "char")
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'setftsweight'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsdoc_concat(ftsdoc, ftsdoc)
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'ftsdoc_concat'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR || (
    LEFTARG = ftsdoc, RIGHTARG = ftsdoc, FUNCTION = ftsdoc_concat
);
