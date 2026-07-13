/* pg_fts--0.3.4--0.3.5.sql */
\echo Use "ALTER EXTENSION pg_fts UPDATE TO '0.3.5'" to load this file. \quit

-- 0.3.5 hardens the on-disk decode path against corrupt/torn pages (found by a
-- new fuzz harness) and adds an ASan+UBSan / fuzz / property-test / torn-page /
-- 90%-coverage CI regime.  No SQL objects change and there is no on-disk format
-- change, so this upgrade is a no-op.
