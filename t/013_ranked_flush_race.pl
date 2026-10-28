# 013_ranked_flush_race.pl -- ranked index scans racing frequent pending-list flushes.
#
# bm25_topk_visible brackets its candidate generation with the directory
# generation and retries (bounded) when it moves.  Through 1.14.2 the last
# failed attempt freed the candidates and left their count set, so when every
# attempt raced a flush the visibility loop read cand[i] through NULL: SIGSEGV
# (every release since 1.0.7).  Each flush moves the generation twice, so many
# inserters flushing every few documents (pg_fts.pending_flush_threshold) under
# many ranked readers hit it within seconds (a crash in 14 of 20 runs of the
# setup below on 1.14.2 and on 1.14.3 before the fix, PG 17.10 and 18.6; this
# test failed 6 of 6 with 1.14.2's .so and passed 6 of 6 with the fix;
# CHANGELOG 1.14.3).
#
# pgbench drives 8 inserting clients (one row per transaction, threshold 20:
# an inline flush every 20 documents) and 8 ranked reader clients.  Nothing may
# crash or error, and afterwards the index must agree with the heap.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run qw(start finish);

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', "fsync = off\n");
$node->append_conf('postgresql.conf', "autovacuum = off\n");
$node->append_conf('postgresql.conf', "max_connections = 40\n");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_fts');
$node->safe_psql('postgres', q{
    CREATE TABLE ds (id bigserial PRIMARY KEY, body text);
    INSERT INTO ds (body) SELECT 'old apple w' || (g % 50) FROM generate_series(1, 2000) g;
    CREATE INDEX ds_fts ON ds USING fts (to_ftsdoc('simple', body));
    ALTER DATABASE postgres SET pg_fts.pending_flush_threshold = 20;
});

my $secs = 15;
my $script = $node->basedir . '/ins.sql';
open(my $fh, '>', $script) or die;
print $fh "INSERT INTO ds (body) VALUES ('fresh apple w' || ((random() * 50)::int));\n";
close($fh);
my $rscript = $node->basedir . '/read.sql';
open($fh, '>', $rscript) or die;
print $fh "SET enable_seqscan = off;\nSET enable_bitmapscan = off;\n"
  . "SELECT count(*) FROM (SELECT id FROM ds WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> 'fresh'::ftsquery LIMIT 10) s;\n"
  . "SELECT count(*) FROM (SELECT id FROM ds WHERE to_ftsdoc('simple', body) @@@ 'fresh & apple'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> 'fresh & apple'::ftsquery LIMIT 1000) s;\n";
close($fh);

my ($bout, $berr) = ('', '');
my $bh = start(['pgbench', '-n', '-c', '8', '-j', '8', '-T', $secs, '-f', $script,
                '-h', $node->host, '-p', $node->port, 'postgres'],
               '>', \$bout, '2>', \$berr);
my ($rout, $rerr) = ('', '');
my $rh = start(['pgbench', '-n', '-c', '8', '-j', '8', '-T', $secs, '-f', $rscript,
                '-h', $node->host, '-p', $node->port, 'postgres'],
               '>', \$rout, '2>', \$rerr);
finish($bh);
finish($rh);

my $log = slurp_file($node->logfile);
is(($log =~ /terminated by signal/) ? 1 : 0, 0, 'no backend terminated by a signal');
my $bench_ok = ($bout =~ /number of failed transactions: 0 / && $berr !~ /error|aborted/i) ? 1 : 0;
diag("inserter pgbench:\n$bout\n$berr") unless $bench_ok;
ok($bench_ok, 'every insert succeeded');
my $read_ok = ($rout =~ /number of transactions actually processed: [1-9]/
               && $rout =~ /number of failed transactions: 0 / && $rerr !~ /error|aborted/i) ? 1 : 0;
diag("reader pgbench:\n$rout\n$rerr") unless $read_ok;
ok($read_ok, 'every concurrent ranked read succeeded');

# the race really ran: rows were inserted and flushed into segments
my $fresh = $node->safe_psql('postgres', q{SELECT count(*) FROM ds WHERE body ~ '\mfresh\M'});
ok($fresh > 1000, "inserters wrote rows ($fresh)");
cmp_ok($node->safe_psql('postgres', q{SELECT fts_index_nsegments('ds_fts')}), '>', 1,
       'inline flushes created segments');
is($node->safe_psql('postgres', q{SELECT count(*) FROM ds WHERE to_ftsdoc('simple', body) @@@ 'fresh'::ftsquery}),
   $fresh, 'index count == heap count after the race');

$node->stop;
done_testing();
