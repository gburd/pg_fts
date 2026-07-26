/* pg_fts 1.0.8 -> 1.1.0
 *
 * 1.1.0 fixes non-converging builds on large, high-vocabulary corpora (an O(N)
 * trigram build and an adaptive tiered build finalization), adds the
 * pg_fts.build_collapse_max_mb GUC and build-progress logging, and makes
 * fts_index_nsegments() work on an in-progress index.  None of this changes any
 * SQL object or the on-disk index format; no REINDEX is required.  This upgrade
 * script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.0'" to load this file. \quit
