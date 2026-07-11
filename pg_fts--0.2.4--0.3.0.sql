/* pg_fts--0.2.4--0.3.0.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.3.0'" to load this file. \quit

-- 0.3.0 adds an on-disk index format (BM25 v2 -> v3): token positions can be
-- stored in the postings via a new `positions` reloption, so phrase/NEAR is
-- answered from the index with no heap recheck.  No SQL objects change here, but
-- the bm25 ON-DISK FORMAT changed: after ALTER EXTENSION + installing the new
-- library, existing bm25 indexes are v2 and the loaded library rejects them with
-- a clear error until REINDEXed.  REINDEX each bm25 index; add
-- WITH (positions = on) (recreate the index) to enable fast index-native phrase.
