SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
\set d 'to_ftsdoc(''simple'', ''alpha beta'')'
\set q 'to_ftsquery(''simple'', ''alpha | beta'')'
SELECT fts_bm25(:d, :q, 1e12, 2) AS ref \gset
SELECT fts_bm25(:d, :q, 1e12, 2, ARRAY[1e9]::float8[]) AS y \gset
SELECT 'short_1e9' c, round(:y::numeric, 4), :y::float8 = fts_bm25(:d, :q, 1e12, 2, ARRAY[1e9, 1]::float8[]) AS eq;
SELECT fts_bm25(:d, :q, 1e12, 2, ARRAY[1e9, 1e9, 1e9]::float8[]) AS x \gset
SELECT fts_bm25(:d, :q, 1e12, 2, ARRAY[1]::float8[]) AS y \gset
SELECT 'short_after_3' c, round(:y::numeric, 4), :y::float8 = :ref::float8 AS eq;
SELECT fts_bm25(:d, :q, 1e12, 2, ARRAY[1e9]::float8[]) AS x \gset
SELECT fts_bm25(:d, :q, 1e12, 2, '{}'::float8[]) AS y \gset
SELECT 'empty_after_1e9' c, round(:y::numeric, 4), :y::float8 = :ref::float8 AS eq;
SELECT fts_bm25_opts(:d, :q, 1e12, 2, 1.2, 0.75, 'lucene', ARRAY[1e9]::float8[]) AS x \gset
SELECT fts_bm25_opts(:d, :q, 1e12, 2, 1.2, 0.75, 'lucene', '{}'::float8[]) AS y \gset
SELECT 'opts_empty_after_1e9' c, round(:y::numeric, 4), :y::float8 = :ref::float8 AS eq;
