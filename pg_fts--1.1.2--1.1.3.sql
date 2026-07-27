/* pg_fts 1.1.2 -> 1.1.3
 *
 * 1.1.3 changes the segment-merge strategy to leveled (bounded fan-in) so large,
 * high-vocabulary indexes converge.  A C-only change; no SQL objects change and
 * no on-disk format change; no REINDEX.  This upgrade script is intentionally
 * empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.3'" to load this file. \quit
