/* pg_fts 1.1.0 -> 1.1.1
 *
 * 1.1.1 fixes quadratic time in VACUUM/bulk-delete tombstone construction on a
 * large index (a C-only change) and adds documentation.  No SQL object changes
 * and no on-disk format change; no REINDEX is required.  This upgrade script is
 * intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.1'" to load this file. \quit
