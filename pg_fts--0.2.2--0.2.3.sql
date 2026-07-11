/* pg_fts--0.2.2--0.2.3.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.2.3'" to load this file. \quit

-- 0.2.3 is a performance release: ranked `ORDER BY d <=> q LIMIT k` over a
-- boolean AND/NOT query now evaluates the boolean structure lazily during the
-- WAND scan instead of pre-collecting the whole @@@ match set, recovering the
-- AND-query latency cost introduced in 0.2.1.  The fix is in the shared library;
-- no SQL objects change and no REINDEX is required (results are unchanged).
