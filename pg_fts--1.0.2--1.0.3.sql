/* pg_fts--1.0.2--1.0.3.sql */
-- Bug-fix release (huge-allocation guards in the trigram/merge/analyze build
-- paths).  No catalog or on-disk format change from 1.0.2; this upgrade is
-- intentionally a no-op (ALTER EXTENSION pg_fts UPDATE TO '1.0.3').
