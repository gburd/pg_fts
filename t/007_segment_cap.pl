# 007_segment_cap.pl -- writes must never fail because the segment directory
# filled up.
#
# Regression for the field outage: "index hit 128-segment cap under load", which
# forced disabling the index.  pg_fts stores its segment directory as a fixed
# array of BM25_MAX_SEGMENTS (128) descriptors in the metapage.  Each flush of a
# pending buffer / each oversized document becomes a segment; if merging falls
# behind the write rate, the directory used to fill and the NEXT insert threw
#   ERROR: bm25 index ... reached the maximum of 128 segments
# turning a write-heavy workload into a hard outage.  An index access method
# must never refuse a write because internal compaction is behind: adding a
# segment now merges to free a slot and retries instead of erroring.
#
# This drives enough segment-creating writes (oversized docs -> one segment
# each) to blow WAY past 128 segments, from several concurrent inserters plus a
# concurrent reader, and asserts: no insert ever hit the cap error, and every
# inserted row is searchable afterward.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run qw(start finish);

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', "fsync = off\n");
$node->append_conf('postgresql.conf', "shared_buffers = 32MB\n");
# tiny mwm so eager merges pick small batches; the point is the cap, not memory
$node->append_conf('postgresql.conf', "maintenance_work_mem = 1MB\n");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_fts');
# An "oversized" document (its analyzed ftsdoc exceeds one pending page) is
# indexed as its own segment immediately -- the fastest way to mint segments.
# Build a big body: many distinct terms so the ftsdoc is large.
$node->safe_psql('postgres', q{
    CREATE TABLE docs (id bigserial PRIMARY KEY, body text);
    CREATE INDEX docs_bm25 ON docs USING fts (to_ftsdoc('simple', body));
});

# helper: a big unique body ~ tens of KB of distinct tokens -> oversized segment
my $bodyexpr = q{'capterm ' || string_agg('t'||s||'x'||$SID||'r'||b||'w'||g, ' ')};

sub inserter_sql {
    my ($sid) = @_;
    # each backend inserts N oversized docs; across all backends this far
    # exceeds 128 segments unless merging keeps making room.
    my $expr = $bodyexpr;
    $expr =~ s/\$SID/$sid/g;
    return qq{
DO \$\$
DECLARE b int := 0;
BEGIN
  WHILE b < 60 LOOP
    INSERT INTO docs(body)
      SELECT 'capterm ' || string_agg('t'||s||'x'||$sid||'r'||b||'w'||g, ' ')
      FROM generate_series(1,1) g, generate_series(1,4000) s;
    b := b + 1;
  END LOOP;
  RAISE NOTICE 'INSERTER_DONE sid=$sid rows=%', b;
END \$\$;
};
}

# a concurrent reader, to also exercise read+write+merge together
my $reader_sql = q{
DO $$
DECLARE dl timestamptz := clock_timestamp() + interval '15 seconds'; c bigint;
BEGIN
  WHILE clock_timestamp() < dl LOOP
    SELECT count(*) INTO c FROM docs WHERE to_ftsdoc('simple', body) @@@ 'capterm'::ftsquery;
  END LOOP;
END $$;
};

sub psql_proc {
    my ($sql) = @_;
    # Terminate the script with \q: with stdin fed from a scalar and pumped
    # non-blocking, psql otherwise sits in ClientRead forever after the last
    # statement, and the timeout loop below cannot tell that from a hang.
    $sql .= "\n\\q\n" unless $sql =~ /\\q\s*$/;
    my ($in, $out, $err) = ($sql, '', '');
    my $h = start(['psql', '-X', '-v', 'ON_ERROR_STOP=0', '-d', $node->connstr('postgres')],
                  '<', \$in, '>', \$out, '2>', \$err);
    return ($h, \$out, \$err);
}

# 4 concurrent inserters (240 oversized docs total -> ~240 segments if unmerged,
# well past the 128 cap) + 1 reader
my @ins;
push @ins, [ psql_proc(inserter_sql($_)) ] for (1 .. 4);
my ($rh, $rout, $rerr) = psql_proc($reader_sql);

# ...plus a CONCURRENT VACUUM, which runs the index cleanup's merge in its own
# backend while the inserters' full-directory merges run in theirs.
#
# This is the regression case for a deadlock that shipped in every release up to
# 1.8.2: bm25_add_segment_with_room() -- the insert path's "directory is full, merge
# to make room" -- was the ONLY merger that did not take the maintenance mutex, so it
# ran concurrently with autovacuum's merge on the same index.  Under extend-only
# allocation the two never touched the same block and it was merely wasteful; the
# moment merges reused freed pages (1.8.3) both mergers handed out the same block and
# deadlocked on its buffer lock.  Reproduced at row 680 and again at row 1,184 of a
# 5,000-row ingest round with autovacuum on; the shipped 1.8.2 deadlocked the same
# way at row 1,674 with no other change.
#
# Repeated VACUUMs (not one) so the window is hit reliably: the inserters take a few
# seconds to fill the directory, and cleanup must be merging AT that moment.
my $vac_sql = join("\n", map { "VACUUM docs;\nSELECT pg_sleep(0.2);" } 1 .. 40) . "\n\\q\n";
my ($vh, $vout, $verr) = psql_proc($vac_sql);

# If the deadlock is present nothing below returns.  IPC::Run's finish() has no
# timeout of its own, so bound the whole phase: a hang is the FAILURE this test
# exists to detect and must show up as a failed test, not a stuck CI job.
my $deadline = time() + 300;
my @all = (@ins, [ $rh, $rout, $rerr ], [ $vh, $vout, $verr ]);
my $hung = 0;
# Pump EVERY harness each iteration.  Pumping one at a time starves the others
# (their psql never receives stdin), and since the inserters contend on the segment
# cap they need each other to make progress -- that looked exactly like the deadlock
# this test hunts, on the fixed code, until the wait events said ClientRead.
while (time() < $deadline) {
    my $live = 0;
    for my $p (@all) {
        next unless $p->[0]->pumpable;
        $live++;
        $p->[0]->pump_nb;
    }
    last if $live == 0;
    select(undef, undef, undef, 0.1);
}
$hung = 1 if time() >= $deadline;
finish($_->[0]) for grep { !$hung } @all;
if ($hung) {
    diag("HUNG: concurrent inserters + VACUUM did not finish in 300s (concurrent-merge deadlock)");
    diag($node->safe_psql('postgres',
        q{SELECT pid, wait_event_type, wait_event, left(query,40) FROM pg_stat_activity
          WHERE backend_type IN ('client backend','autovacuum worker') AND pid <> pg_backend_pid()}));
    $_->[0]->kill_kill for @all;
}
is($hung, 0, 'inserters filling the segment directory and a concurrent VACUUM both complete (no concurrent-merge deadlock)');

my $ins_err = join("\n", map { ${ $_->[2] } } @ins);
my $all_err = "$ins_err\n$$rerr";

# THE assertion: no write ever failed because the directory filled.
my $cap_hit = ($all_err =~ /maximum of \d+ segments|reached the maximum|could not free a segment-directory slot/i) ? 1 : 0;
is($cap_hit, 0, 'no insert failed with a segment-cap error under concurrent write load');

my $any_err = ($ins_err =~ /\bERROR:/) ? 1 : 0;
if ($any_err) {
    my @e = grep { /\bERROR:/ } split /\n/, $ins_err;
    diag("inserter errors:\n" . join("\n", @e[0 .. ($#e < 8 ? $#e : 8)]));
}
is($any_err, 0, 'no inserter backend errored at all');

# All inserted rows must be searchable (data intact + merges preserved postings).
my $total = $node->safe_psql('postgres', 'SELECT count(*) FROM docs');
my $match = $node->safe_psql('postgres',
    q{SET enable_seqscan=off;
      SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) @@@ 'capterm'::ftsquery});
is($match, $total, "every inserted doc ($total) is searchable after the cap churn");

# The directory is bounded (merges kept it under the hard cap).
my $nseg = $node->safe_psql('postgres', q{SELECT fts_index_nsegments('docs_bm25')});
diag("final segments = $nseg (hard cap 128), rows = $total");
cmp_ok($nseg, '<=', 128, 'live segment count stayed within the hard cap');

# ...and comfortably under it, not merely inside it.
#
# The insert-time merge is deliberately NOT run on every insert (it would rewrite a
# whole run per oversized document: measured 23-30 index pages extended per document at
# 1660 terms/doc).  It is gated on there being BM25_MERGE_FANOUT small runs waiting.
# That gate is what this bound protects: if deferral ever stops keeping up, the
# directory creeps toward the cap and the index reaches the state a field deployment hit
# (8 -> 128 segments in ~1h, after which it could neither merge nor VACUUM) -- and a
# `<= 128` assertion would not notice until it was already too late.
#
# Measured with the gate in place, under one-row-per-transaction ingest (the worst case
# for segment minting): max 15 segments over 4,000 single-row transactions.
# See bench/RESULTS_KNOWN_ISSUES_2026-09-14.md.
cmp_ok($nseg, '<=', 64, 'segment count stays well under the cap, not just inside it');

$node->stop;
done_testing();
