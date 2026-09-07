/* pg_fts--1.5.9--1.5.10.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '1.5.10'" to load this file. \quit

-- 1.5.10 is a C-only performance release (common-term ranked top-k 1.56x).
-- No SQL objects changed, no on-disk index format change (BM25_VERSION stays 4),
-- no REINDEX required, nothing to do beyond the ALTER EXTENSION.
