/* pg_fts--1.5.3--1.5.4.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.4'" to load this file. \quit

-- 1.5.4 is a C-only release (relcache-cached doclen sidecar + block-max WAND
-- multi-term AND soundness).  No SQL objects and no on-disk index format change
-- (BM25_VERSION stays 4); no REINDEX required.
