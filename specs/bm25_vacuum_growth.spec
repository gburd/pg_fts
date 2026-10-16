# VACUUM must not grow the fts file when it cannot truncate (1.14.1).
#
# Truncating the index needs AccessExclusiveLock on it, taken conditionally, so
# any session holding any lock on the index -- here a reader in an open
# transaction -- makes VACUUM leave its free tail in place (1.11.0).  The
# cleanup's compaction then still ran its extend-only "vacate" rewrite, whose
# growth only that truncation gives back: each VACUUM met by a reader grew the
# file by about the live size and never gave it back, from 1.11.0 to 1.14.0.
# The vacate now runs only under AccessExclusiveLock (fts_vacuum), so the size
# holds while the reader stays, and the first VACUUM after it leaves reclaims
# the space.
#
# Layout: build, then insert as many rows again and fts_merge, which writes the
# merged segment above its freed inputs -- a free region at the front of the
# file that the cleanup's compaction gate (>= 25% free) acts on.

setup
{
    CREATE EXTENSION IF NOT EXISTS pg_fts;
    CREATE TABLE vg (id int PRIMARY KEY, d ftsdoc) WITH (autovacuum_enabled = off);
    INSERT INTO vg SELECT g, to_ftsdoc('simple', 'alpha w' || (g % 500) || ' x' || (g % 37) || ' doc' || g)
        FROM generate_series(1, 20000) g;
    CREATE INDEX vg_fts ON vg USING fts (d);
}
setup
{
    SET pg_fts.pending_flush_threshold = 0;
    INSERT INTO vg SELECT g, to_ftsdoc('simple', 'alpha w' || (g % 500) || ' y' || (g % 41) || ' doc' || g)
        FROM generate_series(20001, 40000) g;
}
setup
{
    SELECT fts_merge('vg_fts') IS NOT NULL AS merged;
}

teardown
{
    DROP TABLE vg;
}

# A reader in an open transaction: planning the query locks every index on vg,
# and the lock is held until COMMIT.
session "r"
setup           { SET enable_seqscan = off; }
step "r_lock"   { BEGIN; SELECT count(*) > 0 AS found FROM vg WHERE d @@@ 'alpha'::ftsquery; }
step "r_end"    { COMMIT; }

session "v"
step "v_base"   { CREATE TEMP TABLE base AS SELECT pg_relation_size('vg_fts') AS s0; }
step "v_del"    { DELETE FROM vg WHERE id % 97 = 0; }
step "v_vac"    { VACUUM vg; }
step "v_held"   { SELECT pg_relation_size('vg_fts') <= s0 + 16 * 8192 AS no_growth_while_locked FROM base; }
step "v_freed"  { SELECT pg_relation_size('vg_fts') < s0 * 3 / 4 AS reclaimed_after_unlock FROM base; }
step "v_count"  { SET enable_seqscan = off;
                  SELECT (SELECT count(*) FROM vg WHERE d @@@ 'alpha'::ftsquery)
                       = (SELECT count(*) FROM vg WHERE fts_match(d, 'alpha'::ftsquery)) AS index_matches_heap; }

# Two VACUUMs after the reader leaves (as vacuum_parallel does): the first may
# still see the merge-freed pages inside the xmin horizon and not reuse them.
permutation "v_base" "r_lock" "v_del" "v_vac" "v_vac" "v_vac" "v_held" "r_end" "v_vac" "v_vac" "v_freed" "v_count"
