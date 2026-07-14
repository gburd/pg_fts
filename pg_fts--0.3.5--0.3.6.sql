/* pg_fts--0.3.5--0.3.6.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.3.6'" to load this file. \quit

-- 0.3.6 makes the extension installable on non-UTF-8 server encodings: the
-- fts_snippet ellipsis default changed from a UTF-8 ellipsis glyph to ASCII
-- '...' (the non-ASCII default broke CREATE EXTENSION on LATIN1/EUC_JP/etc.).
-- Re-create fts_snippet with the ASCII default; no other SQL objects change,
-- no on-disk format change.
CREATE OR REPLACE FUNCTION fts_snippet(doc text, query ftsquery,
                            pre text DEFAULT '<b>', post text DEFAULT '</b>',
                            ellipsis text DEFAULT '...', max_tokens int DEFAULT 15)
RETURNS text
AS 'MODULE_PATHNAME', 'fts_snippet'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
