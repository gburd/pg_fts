# 008_vacuum_reclaim.pl -- fts_vacuum() must SHRINK a bloated index, not grow it.
#
# Regression for a bug the deletion-XID recycle gate introduced: the gate made
# bm25_new_buffer refuse to reuse just-freed pages until their free-XID horizon
# passed.  That is correct for the concurrent INSERT/merge path, but fts_vacuum
# (single-writer, exclusive lock) MUST be able to repack live data into the low
# pages it just freed -- with the gate blocking that, the vacate+pack phase
# extended the relation instead, so fts_vacuum() GREW the index every call
# (e.g. 182MB -> 340MB -> 498MB) and never truncated a tail.  The fix bypasses
# the recycle gate during compaction (bm25_lowfree active).
#
# This builds an index, runs fts_vacuum() twice, and asserts: it does not grow,
# it reaches a stable floor, and a second call is idempotent (no further change).

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', "fsync = off\n");
$node->append_conf('postgresql.conf', "shared_buffers = 256MB\n");
$node->append_conf('postgresql.conf', "maintenance_work_mem = 64MB\n");
$node->append_conf('postgresql.conf', "autovacuum_naptime = 1s\n");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_fts');
# a corpus large enough that the index spans many pages (so bloat/truncation is
# measurable), high enough vocabulary that merges actually move pages around.
$node->safe_psql('postgres', q{
    CREATE TABLE docs (id bigserial PRIMARY KEY, body text);
    INSERT INTO docs(body)
      SELECT (SELECT string_agg('w'||((g*7+s)%4000), ' ') FROM generate_series(1,40) s)
             || ' uid'||g
      FROM generate_series(1, 120000) g;
    CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body));
});

sub idxpages {
    return $node->safe_psql('postgres',
        q{SELECT (pg_relation_size('docs_fts')/current_setting('block_size')::int)::int});
}

my $built = idxpages();
diag("index pages after build: $built");

# First fts_vacuum: must not grow, should compact to a floor.
$node->safe_psql('postgres', q{SELECT fts_vacuum('docs_fts')});
my $v1 = idxpages();
diag("index pages after fts_vacuum #1: $v1");

# Second fts_vacuum: idempotent (already at floor).
$node->safe_psql('postgres', q{SELECT fts_vacuum('docs_fts')});
my $v2 = idxpages();
diag("index pages after fts_vacuum #2: $v2");

# THE assertions: fts_vacuum never grows the index, and converges.
cmp_ok($v1, '<=', $built, 'fts_vacuum() does not grow the index (reclaims, not extends)');
cmp_ok($v2, '<=', $v1 + 1, 'a second fts_vacuum() is idempotent (stable floor, +/-1 page)');

# And the index is still correct after compaction.
my $c = $node->safe_psql('postgres',
    q{SET enable_seqscan=off;
      SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'w7'::ftsquery});
my $seq = $node->safe_psql('postgres',
    q{SET enable_indexscan=off; SET enable_bitmapscan=off;
      SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'w7'::ftsquery});
is($c, $seq, 'index results still correct after fts_vacuum compaction');

# An autovacuum of the fts index (1.18.0).  Its bulk delete and cleanup run
# under pg_fts's maintenance buffer ring; until 1.18.0 that ring was a
# bulk-write one, which pg_stat_io does not track for an autovacuum worker, and
# an assert-enabled server aborted the worker on its first read
# (pgstat_count_io_op): "terminated by signal 6" in the log, and with
# restart_after_crash off the server stopped.  A server built without asserts
# counts the I/O silently, so there this checks only that the index still
# answers; the assert-enabled gate is what catches a regression.
my $logstart = -s $node->logfile;
$node->safe_psql('postgres', q{
    ALTER TABLE docs SET (autovacuum_vacuum_threshold = 0,
                          autovacuum_vacuum_scale_factor = 0.01);
    DELETE FROM docs WHERE id % 10 = 0;
});
$node->poll_query_until('postgres', q{
    SELECT autovacuum_count > 0 FROM pg_stat_user_tables WHERE relname = 'docs'
}) or die 'autovacuum did not vacuum docs';
my $log = slurp_file($node->logfile, $logstart);
unlike($log, qr/autovacuum worker .* was terminated by signal/,
       'the autovacuum worker that vacuumed the fts index did not crash');
my $after = $node->safe_psql('postgres',
    q{SET enable_seqscan=off;
      SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'w7'::ftsquery});
my $after_seq = $node->safe_psql('postgres',
    q{SET enable_indexscan=off; SET enable_bitmapscan=off;
      SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'w7'::ftsquery});
ok($after > 0 && $after == $after_seq,
   "server survived the autovacuum and the index matches the heap ($after)");

$node->stop;
done_testing();
