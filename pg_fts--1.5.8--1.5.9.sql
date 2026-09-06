/* pg_fts--1.5.8--1.5.9.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.9'" to load this file. \quit

-- 1.5.9 is a C-only release (non-UTF-8 case-folding correctness fix, plus two
-- ranked-latency optimisations).  No SQL objects and no on-disk index format
-- change (BM25_VERSION stays 4).
--
-- UTF-8 databases: nothing to do; no REINDEX required.
--
-- NON-UTF-8 databases (LATIN1/WIN1252/etc) WITH A NON-C LOCALE: the fold fix
-- changes how non-ASCII terms are normalized, so terms already stored by an
-- older version are unfolded and will not match the newly-folded query form.
-- To pick up the fix on existing data, re-derive the terms:
--   * stored ftsdoc column:  UPDATE t SET d = to_ftsdoc('<cfg>', body);
--                            (then REINDEX, or let the update rewrite the index)
--   * expression index:      REINDEX INDEX <name>;
-- Until then such rows keep the old (case-sensitive for non-ASCII) behaviour.
