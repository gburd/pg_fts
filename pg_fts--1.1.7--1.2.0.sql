/* pg_fts 1.1.7 -> 1.2.0
 *
 * 1.2.0 re-numbers the 1.1.6 + 1.1.7 changes as a minor release and documents
 * the recommended REINDEX (1.1.6 changed ranked ORDER BY <=> scan results).
 * No SQL objects change and no on-disk format change.  This upgrade script is
 * intentionally empty.  See the CHANGELOG for the recommended REINDEX.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.2.0'" to load this file. \quit
