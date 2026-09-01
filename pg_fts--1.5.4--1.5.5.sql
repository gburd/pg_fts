/* pg_fts--1.5.4--1.5.5.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.5'" to load this file. \quit

-- 1.5.5 is a C-only release (fixes a concurrent-index-extend crash introduced
-- by 1.5.4's doclen cache).  No SQL objects and no on-disk index format change
-- (BM25_VERSION stays 4); no REINDEX required.
