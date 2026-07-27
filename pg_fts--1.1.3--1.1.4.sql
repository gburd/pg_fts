/* pg_fts 1.1.3 -> 1.1.4
 *
 * 1.1.4 fixes segment-merge convergence + a rare merge crash on large indexes
 * (C-only).  No SQL objects change and no on-disk format change; no REINDEX.
 * This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.4'" to load this file. \quit
