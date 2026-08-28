/* pg_fts--1.4.1--1.5.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.0'" to load this file. \quit

-- 1.5.0 moves per-document length out of the posting lists into a per-segment
-- quantized sidecar (on-disk format v3 -> v4).  This is a C-only change: no SQL
-- objects change.  Existing indexes keep working WITHOUT REINDEX -- the new
-- build dual-reads v3 (inline doclen) and v4 (sidecar) segments, and segments
-- migrate to v4 as merge/vacuum rewrites them.
