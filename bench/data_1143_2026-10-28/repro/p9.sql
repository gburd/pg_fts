SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
\set d 'to_ftsdoc(''simple'', ''alpha beta'')'
\set q 'to_ftsquery(''simple'', ''alpha | beta'')'
SELECT 'A_round' c, round(fts_bm25(:d, :q, 1000, 2, ARRAY[500]::float8[])::numeric, 4);
SELECT 'A_round_empty' c, round(fts_bm25(:d, :q, 1000, 2, '{}'::float8[])::numeric, 4);
SELECT 'B_raw' c, fts_bm25(:d, :q, 1000, 2, ARRAY[500]::float8[]);
SELECT 'B_raw_empty' c, fts_bm25(:d, :q, 1000, 2, '{}'::float8[]);
SELECT 'C_raw' c, fts_bm25(:d, :q, 1000, 2, ARRAY[500]::float8[]);
SELECT 'C_eq' c, fts_bm25(:d, :q, 1000, 2, '{}'::float8[]) = fts_bm25(:d, :q, 1000, 2);
SELECT fts_bm25(:d, :q, 1000, 2, ARRAY[500]::float8[]) AS x \gset
SELECT fts_bm25(:d, :q, 1000, 2, '{}'::float8[]) AS y \gset
SELECT 'D_gset' c, round(:y::numeric, 4);
SELECT fts_bm25(:d, :q, 1e12, 2, ARRAY[123456789]::float8[]) AS x \gset
SELECT fts_bm25(:d, :q, 1e12, 2, '{}'::float8[]) AS y \gset
SELECT 'E_gset_bign' c, round(:y::numeric, 4);
SELECT 'F' c, fts_bm25(:d, :q, 1000, 2, ARRAY[500]::float8[]) > 0;
SELECT 'F_empty_eq_null' c, fts_bm25(:d, :q, 1000, 2, '{}'::float8[]) - 13.006579342414113 < 1e-9;
