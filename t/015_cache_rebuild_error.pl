# 015_cache_rebuild_error.pl -- an ERROR while the relcache cache is rebuilt must not leak it (ROADMAP I8).
#
# bm25_doclendir_cache rebuilds the per-index cache (page directory, slot arrays,
# dictionary directories) in CacheMemoryContext when the segment directory
# changes.  Through 1.14.3 the chunk was attached to rd_amcache only after the
# last builder, so an ERROR in between (a cancel, a read error, out of memory)
# leaked it for the backend's life, once per failed rebuild (since 1.5.8;
# CHANGELOG 1.15.0).  1.15.0 attaches each chunk as soon as it exists.
#
# Deterministic with a test-hooks build: pg_fts.test_cache_build_error raises an
# ERROR between the builders.  One session forces 40 failed rebuilds (a merge
# moves the generation before each) and reads CacheMemoryContext's total before
# and after (pg_backend_memory_contexts, same session; the "before" is taken
# after a warm-up rebuild so the cache's own size is in both).  Skipped without the hooks;
# PG_FTS_TEST_HOOKS_BUILD=1 makes a missing hook a failure.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', "autovacuum = off\n");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_fts');

my $has_hook = $node->safe_psql('postgres',
    q{LOAD 'pg_fts'; SELECT count(*) FROM pg_settings WHERE name = 'pg_fts.test_cache_build_error'});
if ($has_hook ne '1')
{
    if ($ENV{PG_FTS_TEST_HOOKS_BUILD})
    {
        fail('test-hooks build expected (PG_FTS_TEST_HOOKS_BUILD=1) but the hook GUC is missing');
        done_testing();
        exit 0;
    }
    plan skip_all => 'needs a -DPG_FTS_TEST_HOOKS build';
}

# 60k docs over 4000 terms: a segment big enough that the cache chunk is ~100 kB+
$node->safe_psql('postgres', q{
    CREATE TABLE cr (id int, body text) WITH (autovacuum_enabled = off);
    INSERT INTO cr SELECT g, 'w' || (g % 4000) || ' x' || (g % 37) || ' common'
      FROM generate_series(1, 60000) g;
    CREATE INDEX cr_fts ON cr USING fts (to_ftsdoc('simple', body));
});

# one session: warm the cache, measure, then 40 x (flush -> failing rebuild), measure
my $out = $node->safe_psql('postgres', q{
    LOAD 'pg_fts';
    SET pg_fts.pending_flush_threshold = 0;
    SET enable_seqscan = off; SET enable_bitmapscan = off;
    CREATE FUNCTION pg_temp.ranked() RETURNS int LANGUAGE sql AS $$
      SELECT count(*)::int FROM (SELECT id FROM cr WHERE to_ftsdoc('simple', body) @@@ 'common'::ftsquery
        ORDER BY to_ftsdoc('simple', body) <=> 'common'::ftsquery LIMIT 10) s $$;
    -- used, not total: total grows in whole blocks (512 kB -> 1 MB once), not per chunk
    CREATE FUNCTION pg_temp.cache_bytes() RETURNS bigint LANGUAGE sql AS $$
      SELECT used_bytes FROM pg_backend_memory_contexts WHERE name = 'CacheMemoryContext' $$;
    SELECT pg_temp.ranked();
    CREATE TEMP TABLE m AS SELECT pg_temp.cache_bytes() AS b0;
    DO $d$
    DECLARE n int := 0;
    BEGIN
      FOR i IN 1..40 LOOP
        INSERT INTO cr VALUES (100000 + i, 'common fresh' || i);
        PERFORM fts_merge('cr_fts');            -- new segment: the cache is stale
        BEGIN
          SET LOCAL pg_fts.test_cache_build_error = on;
          PERFORM pg_temp.ranked();
        EXCEPTION WHEN OTHERS THEN
          IF SQLERRM LIKE '%test hook%' THEN n := n + 1; END IF;
        END;
        SET pg_fts.test_cache_build_error = off;
      END LOOP;
      RAISE NOTICE 'hook_errors=%', n;
      PERFORM set_config('cr.errors', n::text, false);
    END $d$;
    SELECT pg_temp.ranked();                     -- rebuilds cleanly
    SELECT current_setting('cr.errors') || ' ' || b0 || ' ' || pg_temp.cache_bytes() FROM m;
});
my @l = split /\n/, $out;
my ($nerr, $b0, $b1) = split / /, $l[-1];
diag("rebuild errors=$nerr CacheMemoryContext used before=$b0 after=$b1");
is($nerr, '40', 'all 40 rebuilds raised the hook ERROR');
cmp_ok($l[-2], '==', 10, 'ranked query still answers after the failed rebuilds');
# CacheMemoryContext used_bytes over the 40 failed rebuilds: see CHANGELOG 1.15.0 for
# the measured growth on 1.14.3 (about one cache chunk per failed rebuild) and on the
# fix.  64 kB is far above the fix's noise and far below the 1.14.3 growth.
cmp_ok($b1 - $b0, '<', 64 * 1024, 'CacheMemoryContext did not grow per failed rebuild');

$node->stop;
done_testing();
