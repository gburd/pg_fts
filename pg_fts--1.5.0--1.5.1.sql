/* pg_fts--1.5.0--1.5.1.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.1'" to load this file. \quit

-- 1.5.1 is a C-only bug-fix release (version-aware v3 metapage dual-read;
-- forward-cursored doclen sidecar).  No SQL objects change.  No REINDEX.
