/* pg_fts--0.2.1--0.2.2.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.2.2'" to load this file. \quit

-- 0.2.2 is a bug-fix release: phrase ("a b c") and NEAR queries now enforce term
-- adjacency on all paths (they previously degraded to AND on the primary
-- to_ftsdoc(regconfig, text) path).  The fix is in the shared library; no SQL
-- objects change.
--
-- No REINDEX is required (the bm25 on-disk index format is unchanged).  However,
-- phrase/NEAR correctness depends on token positions in the ftsdoc value:
--   * Expression indexes -- CREATE INDEX ... USING fts (to_ftsdoc('english', col))
--     -- recompute to_ftsdoc() at scan time, so phrase queries are correct
--     immediately after loading the new library.
--   * A STORED ftsdoc column populated by the OLD analyzer lacks positions; those
--     rows must be re-analyzed (re-run to_ftsdoc over the source text) for phrase
--     adjacency to be enforced on them.
