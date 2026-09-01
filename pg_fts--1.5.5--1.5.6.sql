/* pg_fts--1.5.5--1.5.6.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.6'" to load this file. \quit

-- 1.5.6 is a C-only release (fixes an uninitialized-field crash in 1.5.4/1.5.5's
-- doclen cursor).  No SQL objects and no on-disk index format change
-- (BM25_VERSION stays 4); no REINDEX required.
