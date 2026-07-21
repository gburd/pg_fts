/* pg_fts--1.0.3--1.0.4.sql */
-- Scale-hardening release. No on-disk format change from 1.0.3.
--
-- fts_index_stats' nterms OUT parameter widens from int to bigint so a very
-- large index's total distinct-term count cannot overflow int32. Changing an
-- OUT-parameter type requires DROP + CREATE (CREATE OR REPLACE cannot change a
-- function's result type).
DROP FUNCTION IF EXISTS fts_index_stats(regclass);
CREATE FUNCTION fts_index_stats(regclass,
                                OUT ndocs float8, OUT avgdl float8,
                                OUT nterms bigint)
RETURNS record
AS 'MODULE_PATHNAME', 'fts_index_stats'
LANGUAGE C STRICT PARALLEL SAFE;
