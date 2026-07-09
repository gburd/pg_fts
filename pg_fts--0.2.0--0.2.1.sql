/* pg_fts--0.2.0--0.2.1.sql */
-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.2.1'" to load this file. \quit

-- 0.2.1 is a bug-fix release: the ranked `<=>` ordering scan now respects the
-- query's boolean AND/NOT/PHRASE structure (it previously ranked the term
-- disjunction and could return documents that fail `@@@`).  The fix is entirely
-- in the shared library; no SQL objects change.  Existing bm25 indexes need no
-- REINDEX (the on-disk format is unchanged from 0.2.0).
