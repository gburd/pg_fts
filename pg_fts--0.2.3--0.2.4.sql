/* pg_fts--0.2.3--0.2.4.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.2.4'" to load this file. \quit

-- 0.2.4 is a bug-fix release: phrase/NEAR queries silently returned wrong
-- results on a STORED ftsdoc column (the positions[] region was addressed via
-- MAXALIGN of an absolute pointer, which mis-points for a heap-resident,
-- non-MAXALIGN'd document -> phrase degraded to AND on stored columns).  The fix
-- is in the shared library; no SQL objects change and no REINDEX is required.
-- (Expression indexes on to_ftsdoc(col) were unaffected by this bug, but their
-- phrase COUNT remains slow -- a positional-index format change in a later
-- release addresses that.)
