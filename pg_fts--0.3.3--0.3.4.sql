/* pg_fts--0.3.3--0.3.4.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.3.4'" to load this file. \quit

-- 0.3.4 is a crash-safety bug-fix release: the segment posting decoder
-- (bm25_decode_term) now bounds the per-block posting count read from disk and
-- rejects a block whose declared byte lengths run past the page, so a torn or
-- corrupt posting block is a bounded miss (with a WARNING) instead of a stack
-- overflow.  No SQL objects change and there is no on-disk format change, so
-- this upgrade is a no-op.  (The fix lives entirely in the loaded library.)
