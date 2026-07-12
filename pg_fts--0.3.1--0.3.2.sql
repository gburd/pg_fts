/* pg_fts--0.3.1--0.3.2.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.3.2'" to load this file. \quit

-- 0.3.2 is an additive release: Unicode-lowercasing in the built-in analyzer and
-- index-scan accounting in pg_stat_user_indexes.  No SQL objects change and there
-- is no on-disk format change, so this upgrade is a no-op.  (Indexes over
-- non-ASCII text built before 0.3.2 should be REINDEXed so their stored terms are
-- Unicode-lowercased; ASCII-only indexes are unaffected.)
