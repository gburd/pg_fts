/* pg_fts 1.1.4 -> 1.1.5
 *
 * 1.1.5 fixes an O(N^2) CIC-validation phase on large high-vocabulary indexes
 * and adds the pg_fts.build_mem_ceiling_mb GUC (C-only / GUC, registered in
 * _PG_init).  No SQL objects change and no on-disk format change; no REINDEX.
 * This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.1.5'" to load this file. \quit
