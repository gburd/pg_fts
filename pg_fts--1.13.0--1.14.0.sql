/* pg_fts 1.13.0 -> 1.14.0 */

-- I11: a real restriction estimator for @@@ (was tsmatchsel's fixed default).
CREATE FUNCTION fts_matchsel(internal, oid, internal, integer)
RETURNS double precision
AS 'MODULE_PATHNAME', 'fts_matchsel'
LANGUAGE C STRICT;

ALTER OPERATOR @@@ (ftsdoc, ftsquery) SET (RESTRICT = fts_matchsel);
ALTER OPERATOR @@@ (ftsquery, ftsdoc) SET (RESTRICT = fts_matchsel);

/* I12 adds the pg_fts.pending_flush_threshold GUC and a scan path change; no SQL. */
