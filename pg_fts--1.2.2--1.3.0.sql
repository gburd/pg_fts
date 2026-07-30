/* pg_fts 1.2.2 -> 1.3.0
 *
 * 1.3.0 adds the WITH (trigrams=on|off) reloption (default off), a dict-df
 * count(*) fast path + docids-only decode + plain-column count pushdown, ranked-
 * exactness hardening, and managed-service guards (fts_merge/fts_vacuum refuse
 * to run during recovery and require index ownership).  All of that is C-side;
 * no on-disk format change, no REINDEX.
 *
 * The one SQL change is the privilege model: fts_search and fts_anomalous_docs
 * emit indexed content by index OID, so they are revoked from PUBLIC (the index
 * owner and superusers keep access; an owner may grant explicitly).  Apply the
 * same REVOKE to an existing install here.
 */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.3.0'" to load this file. \quit

REVOKE ALL ON FUNCTION fts_search(regclass, ftsquery, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION fts_anomalous_docs(regclass, int, int) FROM PUBLIC;
