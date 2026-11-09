# Corpus N after a build that met recently-dead rows (1.17.0).
#
# A row deleted while another snapshot can still see it is recently dead to
# CREATE INDEX: the build indexes it (that snapshot may reach it through the
# index) with tupleIsAlive = false.  1.3.0 to 1.16.0 then left it out of ndocs,
# and the VACUUM that later removed it tombstoned it and subtracted it again:
# 100 live rows read ndocs = -800.  It is now counted until that VACUUM, like
# any deleted row.

setup
{
    CREATE EXTENSION IF NOT EXISTS pg_fts;
    CREATE TABLE rd (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = off);
    INSERT INTO rd SELECT g, 'alpha w' || g FROM generate_series(1, 1000) g;
}

teardown
{
    DROP TABLE rd;
}

session "reader"
step "r_snap"   { BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) AS seen FROM rd; }
step "r_end"    { COMMIT; }

session "builder"
step "b_delete" { DELETE FROM rd WHERE id <= 900; }
step "b_build"  { CREATE INDEX rd_fts ON rd USING fts (to_ftsdoc('simple', body)); }
step "b_built"  { SELECT ndocs AS ndocs_built FROM fts_index_stats('rd_fts'); }
step "b_vacuum" { VACUUM rd; }
step "b_check"  { SELECT s.ndocs AS ndocs, (SELECT count(*) FROM rd) AS live,
                         s.ndocs = (SELECT count(*) FROM rd) AS agree
                    FROM fts_index_stats('rd_fts') s; }

permutation "r_snap" "b_delete" "b_build" "b_built" "r_end" "b_vacuum" "b_check"
