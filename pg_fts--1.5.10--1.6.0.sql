/* pg_fts--1.5.10--1.6.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.6.0'" to load this file. \quit

-- 1.6.0 is a C-only release.  No SQL objects change, and there is no on-disk
-- index format change (BM25_VERSION stays 4) -- no REINDEX is required.
--
-- MINOR rather than patch because query RESULTS change, for the better:
--
--   * A phrase or NEAR query whose adjacency cannot be verified now returns
--     FALSE instead of silently degrading to a plain conjunction.  This matches
--     PostgreSQL, whose OP_PHRASE "always returns false if lexeme position
--     information is not available" without TS_EXEC_PHRASE_NO_POS.  Previously
--     such a query could report a NON-ADJACENT document as a phrase match.
--     Affected inputs: an ftsdoc built without positions (the canonical literal
--     form, to_ftsdoc(strip(to_tsvector(...))), or a concatenation where one side
--     lacks positions), AND -- on fully positioned documents -- a phrase whose
--     operand is a boolean sub-expression, e.g. 'quick <-> (brown & fox)'.
--     Prefix-inside-phrase ("quick bro*") is UNCHANGED and stays deliberately
--     permissive, since prefix positions are not tracked.
--
--   * A field-zone restriction (term:A) on a document without positions now
--     matches nothing rather than treating unlabeled positions as label D, which
--     had made term:D match every such document.
--
-- If an application relied on the old lossy phrase behaviour as a cheap
-- conjunction, write the conjunction explicitly: 'quick & brown'.
