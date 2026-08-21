/* pg_fts 1.3.1 -> 1.3.2
 *
 * 1.3.2 is a performance bug-fix release: it restores the O(1) block-skip in
 * the block-max WAND ranked scan that the 1.3.0 exactness hardening had turned
 * into per-posting re-pivots (a ~5x common-term ranked-latency regression).
 * C-only (pg_fts_am_scan.c); no SQL objects change and no on-disk index format
 * change; no REINDEX.  This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.3.2'" to load this file. \quit
