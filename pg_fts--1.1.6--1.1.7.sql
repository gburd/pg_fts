/* pg_fts 1.1.6 -> 1.1.7
 *
 * 1.1.7 adds build progress logging (C-only) and documentation.  No SQL objects
 * change and no on-disk format change; no REINDEX.  This upgrade script is
 * intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.7'" to load this file. \quit
