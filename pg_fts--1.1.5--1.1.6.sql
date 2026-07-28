/* pg_fts 1.1.5 -> 1.1.6
 *
 * 1.1.6 fixes ORDER BY <=> ordered index scans truncating the result set
 * (query-side, C-only).  No SQL objects change and no on-disk format change;
 * no REINDEX.  This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.6'" to load this file. \quit
