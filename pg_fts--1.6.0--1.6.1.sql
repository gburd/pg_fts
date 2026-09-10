/* pg_fts--1.6.0--1.6.1.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.6.1'" to load this file. \quit

-- 1.6.1 is a C-only fix release.  No SQL objects change, no on-disk index format
-- change (BM25_VERSION stays 4), no REINDEX -- ALTER EXTENSION is the whole
-- upgrade.
--
-- Fixes a P0: VACUUM on an index with many tombstones could consume CPU
-- indefinitely and never complete (measured 4h39m without finishing; now 393s on
-- the same workload).  If you have been running VACUUM against a delete-heavy
-- pg_fts index and it never returned, this is why -- and because a VACUUM that
-- never completes never reclaims space, an index that appeared not to shrink
-- should now do so.
--
-- Also re-vendors sparsemap 5.4.0 -> 5.5.1.
