# 014_flush_publish_window.pl -- a ranked scan during a pending flush's publish (ROADMAP I20).
#
# Through 1.14.3 a pending flush published its new segment in one metapage update
# and cleared the pending list in a second one.  A ranked scan whose candidate pass
# fell between the two saw every flushed document both in the segment and on the
# pending list: a LIMIT 10 returned 10 rows with 5 distinct ids, and N and df
# counted those documents twice (since 1.13.0, when ranked scans began merging
# pending documents; CHANGELOG 1.15.0).  1.15.0 does both in one update.
#
# Deterministic with a test-hooks build (-DPG_FTS_TEST_HOOKS): the flusher waits on
# pg_fts.test_flush_pause_advisory_key right after the publish, which through
# 1.14.3 was inside the window.  Without the hooks the GUC does not exist and the
# test is skipped.  Set PG_FTS_TEST_HOOKS_BUILD=1 to fail instead of skipping.

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
    q{LOAD 'pg_fts'; SELECT count(*) FROM pg_settings WHERE name = 'pg_fts.test_flush_pause_advisory_key'});
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

$node->safe_psql('postgres', q{
    CREATE TABLE dp (id int, body text) WITH (autovacuum_enabled = off);
    INSERT INTO dp SELECT g, 'old apple' FROM generate_series(1, 200) g;
    CREATE INDEX dp_fts ON dp USING fts (to_ftsdoc('simple', body));
});
# 50 pending documents (no inline flush)
$node->safe_psql('postgres', q{
    SET pg_fts.pending_flush_threshold = 0;
    INSERT INTO dp SELECT g, 'fresh apple' FROM generate_series(201, 250) g;
});
is($node->safe_psql('postgres', q{SELECT (fts_index_stats('dp_fts')).ndocs}), '250', 'ndocs before');

# blocker holds the key; the flusher (fts_merge) publishes, then waits on it
my $blocker = $node->background_psql('postgres');
$blocker->query_safe('SELECT pg_advisory_lock(4242)');
my $flusher = $node->background_psql('postgres');
$flusher->query("LOAD 'pg_fts'");
$flusher->query('SET pg_fts.test_flush_pause_advisory_key = 4242');
$flusher->query_until(qr/start/, "\\echo start\nSELECT fts_merge('dp_fts');\n");

# wait until the flusher is blocked on the advisory lock (it has published)
$node->poll_query_until('postgres', q{
    SELECT count(*) > 0 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted
}) or die 'flusher never reached the pause';

my $q = q{SET enable_seqscan = off; SET enable_bitmapscan = off;};
is($node->safe_psql('postgres', $q . q{
    SELECT count(*) || '/' || count(DISTINCT id) FROM (SELECT id FROM dp
      WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery
      ORDER BY to_ftsdoc('simple', body) <=> 'fresh'::ftsquery LIMIT 1000) s}),
   '50/50', 'ranked scan in the window: each pending row once (1.14.3: 100/50)');
is($node->safe_psql('postgres', $q . q{
    SELECT count(*) || '/' || count(DISTINCT id) FROM (SELECT id FROM dp
      WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery
      ORDER BY to_ftsdoc('simple', body) <=> 'fresh'::ftsquery LIMIT 10) s}),
   '10/10', 'top 10 in the window: 10 distinct rows (1.14.3: 10/5)');
is($node->safe_psql('postgres', q{SELECT (fts_index_stats('dp_fts')).ndocs}),
   '250', 'ndocs in the window (1.14.3: 300)');
is($node->safe_psql('postgres', q{SELECT fts_index_df('dp_fts', 'fresh | apple'::ftsquery)}),
   '{50,250}', 'df in the window (1.14.3: {100,300})');
is($node->safe_psql('postgres', q{SELECT count(*) FROM fts_search('dp_fts', 'fresh'::ftsquery, 1000)}),
   '50', 'fts_search in the window (1.14.3: 100)');

$blocker->query_safe('SELECT pg_advisory_unlock(4242)');
$flusher->quit;
$blocker->quit;

is($node->safe_psql('postgres', $q . q{
    SELECT count(*) || '/' || count(DISTINCT id) FROM (SELECT id FROM dp
      WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery
      ORDER BY to_ftsdoc('simple', body) <=> 'fresh'::ftsquery LIMIT 1000) s}),
   '50/50', 'after the flush');
is($node->safe_psql('postgres', q{SELECT (fts_index_stats('dp_fts')).ndocs}), '250', 'ndocs after');
is($node->safe_psql('postgres',
    q{SELECT count(*) FROM dp WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery}),
   '50', 'count after');

$node->stop;
done_testing();
