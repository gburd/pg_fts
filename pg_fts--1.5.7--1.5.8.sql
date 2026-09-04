/* pg_fts--1.5.7--1.5.8.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.8'" to load this file. \quit

-- 1.5.8 is a C-only release (page-directory doclen cursor, fts_search SRF
-- under-fetch retry, sparsemap error-path cleanup, reserved keywords as literal
-- words in phrase/NEAR).  No SQL objects and no on-disk index format change
-- (BM25_VERSION stays 4); no REINDEX required.
