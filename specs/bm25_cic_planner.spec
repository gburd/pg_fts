# Planning and counting @@@ while CREATE INDEX CONCURRENTLY runs or after it was
# cancelled (1.14.1).  An index that is not yet valid must not be read by the
# @@@ estimator (fts_matchsel) or used by the count(*) pushdown: during CIC's
# first wait its file is empty, and a CIC cancelled between its build and its
# validation leaves an index without the rows of transactions that inserted
# while it was not yet ready.  Nor may the count pushdown use an index too new
# for the transaction's snapshot (indcheckxmin: built over a HOT chain whose
# older version that snapshot still sees).  1.14.0 found indexes through the
# relation's raw index list: every @@@ query on the table failed to plan during
# CIC's first wait ("could not read blocks 0..0"), and count(*) read the
# cancelled index (0 rows instead of 1) and the too-new one (1 and 49 instead
# of 0 and 50) -- the last two since the count pushdown was added.  Both now
# use the planner's index list, which leaves out such indexes.

setup
{
    CREATE EXTENSION IF NOT EXISTS pg_fts;
    CREATE TABLE cicp (id int, d ftsdoc);
    INSERT INTO cicp SELECT g, to_ftsdoc('simple', 'alpha doc ' || g)
        FROM generate_series(1, 2000) g;
    ANALYZE cicp;
    CREATE TABLE hc (id int PRIMARY KEY, d ftsdoc) WITH (fillfactor = 50);
    INSERT INTO hc SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 50) g;
}
setup
{
    VACUUM hc;
}

teardown
{
    DROP TABLE cicp;
    DROP TABLE hc;
}

# w1 holds the table lock CIC waits out before building; w2 inserts while the
# index is not ready, so the build misses its row and CIC waits for w2 next.
session "w1"
step "w1_begin"  { BEGIN; INSERT INTO cicp VALUES (3001, to_ftsdoc('simple', 'beta')); }
step "w1_commit" { COMMIT; }
step "w1_hot"    { UPDATE hc SET d = to_ftsdoc('simple', 'omega') WHERE id = 1; }
step "w1_xmin"   { SELECT indcheckxmin FROM pg_index WHERE indexrelid = 'hc_fts'::regclass; }

session "w2"
step "w2_begin"  { BEGIN; INSERT INTO cicp VALUES (3002, to_ftsdoc('simple', 'omega alpha')); }
step "w2_commit" { COMMIT; }

session "b"
step "b_cic"     { CREATE INDEX CONCURRENTLY cicp_fts ON cicp USING fts (d); }
step "b_hc"      { CREATE INDEX hc_fts ON hc USING fts (d); }

session "r"
step "r_state"   { SELECT indisready, indisvalid, pg_relation_size(indexrelid) > 0 AS has_blocks
                   FROM pg_index WHERE indexrelid = 'cicp_fts'::regclass; }
step "r_plan"    { EXPLAIN (COSTS OFF) SELECT id FROM cicp WHERE d @@@ 'doc & 17'::ftsquery; }
step "r_count"   { SELECT (SELECT count(*) FROM cicp WHERE d @@@ 'omega'::ftsquery) AS omega,
                          (SELECT count(*) FROM cicp WHERE d @@@ 'alpha'::ftsquery) AS alpha; }
step "r_cancel"  { SELECT pg_cancel_backend(pid) FROM pg_stat_activity
                   WHERE query ~ 'CREATE INDEX CONCURRENTLY cicp_fts' AND pid <> pg_backend_pid(); }
step "r_noop"    { }
step "r_drop"    { DROP INDEX cicp_fts; }
step "r_snap"    { BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) AS hc_rows FROM hc; }
step "r_hc"      { SELECT (SELECT count(*) FROM hc WHERE d @@@ 'omega'::ftsquery) AS omega,
                          (SELECT count(*) FROM hc WHERE d @@@ 'alpha'::ftsquery) AS alpha; }
step "r_end"     { COMMIT; }

# 1. CIC is in its first wait: not ready, empty file.
permutation "w1_begin" "b_cic" "r_state" "r_plan" "r_count" "w1_commit" "r_state" "r_count"

# 2. CIC cancelled after the build, before validation; w2's row is in the heap
#    and not in the index.
permutation "w1_begin" "b_cic" "w2_begin" "w1_commit" "r_state" "r_cancel"(b_cic) "r_noop" "w2_commit" "r_state" "r_plan" "r_count" "r_drop"

# 3. A snapshot older than a HOT update, then CREATE INDEX: the index is too new
#    for that snapshot, which still sees 'alpha 1' and no 'omega'.
permutation "r_snap" "w1_hot" "b_hc" "w1_xmin" "r_hc" "r_end"
