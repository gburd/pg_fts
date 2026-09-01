/* pg_fts--1.5.6--1.5.7.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.7'" to load this file. \quit

-- 1.5.7 is a C-only release (concurrency: serialize directory-mutating
-- maintenance, and make scans tolerate a concurrent fts_vacuum truncation).
-- No SQL objects and no on-disk index format change (BM25_VERSION stays 4);
-- no REINDEX required.
