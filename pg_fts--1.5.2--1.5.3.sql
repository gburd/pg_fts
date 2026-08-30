/* pg_fts--1.5.2--1.5.3.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.3'" to load this file. \quit

-- 1.5.3 is a C-only bug-fix release (merge now populates the doclen sidecar; a
-- merged v4 segment no longer degrades to garbage inline doclen).  No SQL
-- objects change.  No REINDEX (but merged-under-<=1.5.2 v4 segments should be
-- rebuilt/re-merged to correct their doclen -- see CHANGELOG).
