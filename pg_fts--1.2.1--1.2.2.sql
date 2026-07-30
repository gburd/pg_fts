/* pg_fts 1.2.1 -> 1.2.2
 *
 * 1.2.2 is a C-only bug-fix release (fts_vacuum reclaim + concurrent-scan
 * safety).  No SQL objects change and no on-disk format change; no REINDEX.
 * This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.2.2'" to load this file. \quit
