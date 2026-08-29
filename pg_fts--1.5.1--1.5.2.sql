/* pg_fts--1.5.1--1.5.2.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.2'" to load this file. \quit

-- 1.5.2 is a C-only bug-fix release (random-access doclen sidecar lookup; new
-- doclen_sidecar reloption).  No SQL objects change.  No REINDEX.
