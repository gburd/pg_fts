/* pg_fts--0.3.2--0.3.3.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.3.3'" to load this file. \quit

-- 0.3.3 is a crash-safety bug-fix release: the pending-list readers now validate
-- each stored document's structure before trusting its term offsets, so a
-- malformed/torn pending page is skipped (with a WARNING) instead of crashing a
-- backend.  No SQL objects change and there is no on-disk format change, so this
-- upgrade is a no-op.  (The fix lives entirely in the loaded library.)
