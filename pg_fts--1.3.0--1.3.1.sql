/* pg_fts 1.3.0 -> 1.3.1
 *
 * 1.3.1 is a correctness bug-fix release: to_ftsquery(regconfig, text) now
 * drops configuration stopwords from the query (matching to_ftsdoc and standard
 * to_tsquery), so a stopword term no longer silently zeroes a boolean query.
 * C-only; no SQL objects change and no on-disk index format change; no REINDEX.
 * This upgrade script is intentionally empty.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.3.1'" to load this file. \quit
