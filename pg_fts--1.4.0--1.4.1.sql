/* pg_fts--1.4.0--1.4.1.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.4.1'" to load this file. \quit

-- 1.4.1 is a C-only bug-fix release (ranked-scan tombstone-bloat performance
-- fix; memory-bounded fuzzy/regex/NOT fallback).  No SQL objects change.
