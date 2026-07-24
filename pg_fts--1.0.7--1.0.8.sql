/* pg_fts 1.0.7 -> 1.0.8
 *
 * 1.0.8 is a memory-only bug-fix (bounded merge-phase memory during large index
 * builds).  No SQL objects change and the on-disk index format is byte-identical
 * to 1.0.7; no REINDEX is required.  This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.0.8'" to load this file. \quit
