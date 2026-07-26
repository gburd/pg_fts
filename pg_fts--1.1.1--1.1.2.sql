/* pg_fts 1.1.1 -> 1.1.2
 *
 * 1.1.2 fixes a hang in the final phase of a large CREATE INDEX CONCURRENTLY
 * (build finalization no longer starts a parallel merge inside ambuild).  A
 * C-only change; no SQL objects change and no on-disk format change; no REINDEX.
 * This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.2'" to load this file. \quit
