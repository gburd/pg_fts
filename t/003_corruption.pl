# Copyright (c) 2024-2026, PostgreSQL Global Development Group

# On-disk corruption / torn-page crash-safety for the pg_fts bm25 index.
#
# A corrupt index block is a BOUNDED MISS, not a crash.  The readers cast raw
# on-disk page bytes to their C structs and then trust the fields inside: the
# segment posting decoder (bm25_decode_term) reads a posting block header's
# `count` and byte lengths, and the pending-list scan/flush cast a pending
# page to an FtsDoc and walk its term offsets.  A torn page, a stale-format
# image, or a producing bug could put a `count` > BM25_BLOCK_SIZE (a stack
# overflow of the fixed 128-element decode arrays) or a bytelen/posbytelen that
# runs the FOR columns past the page (an out-of-bounds read) or a malformed
# pending document (a wild memcpy in add_posting / an OOB read in
# fts_doc_matches).  The 0.3.3/0.3.4 fixes clamp/validate these at the trust
# boundary: a corrupt block or pending doc is skipped with a WARNING and the
# backend SURVIVES.
#
# This test reproduces the reporter's crash directly -- it writes bad bytes
# into the index file with the server down, restarts, and asserts that scans
# and VACUUM over the corrupted index do NOT crash the backend (the connection
# stays alive, the cluster stays up, queries still answer).  It is the pg_fts
# analogue of libxtc's deterministic torn-write fault injection: a corrupt
# input must be a WARNING and a bounded miss, never a segfault.
#
# We inject two kinds of corruption, so the test keeps its teeth even if the
# exact on-disk offset of a header drifts:
#   * TARGETED: overwrite a posting block header's first uint32 (`count`) with
#     0xFFFF (>> BM25_BLOCK_SIZE) -- exercises the 0.3.4 count clamp precisely.
#   * COARSE: 0xFF-smash a run of bytes in a posting page's used content area
#     (after the page header, before pd_lower) -- guaranteed to hit real FOR
#     column bytes / block-header byte-length fields and exercise the
#     past-the-page rejection and general decode robustness.
# Plus a smashed PENDING page (exercises fts_doc_is_valid on the scan + flush
# paths).  The PRIMARY assertion is always "no crash": every query after
# corruption must return through a live connection, and VACUUM must complete.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# On-disk page-layout constants for the bm25 AM (pg_fts_am.h + PG bufpage).
#   BLCKSZ default build (8 KB); MAXALIGN(SizeOfPageHeaderData) = 24 is where a
#   page's contents (and thus the first posting block header / pending item)
#   begin; the page-special BM25PageOpaqueData (flags:uint16) sits at
#   BLCKSZ - MAXALIGN(sizeof(BM25PageOpaqueData)) = 8192 - 8 = 8184; pd_lower
#   (uint16) at page-header offset 12 marks the end of the used content area.
use constant {
	BLCKSZ            => 8192,
	CONTENT_START     => 24,      # MAXALIGN(SizeOfPageHeaderData)
	PD_LOWER_OFF      => 12,      # offset of pd_lower (uint16) in PageHeaderData
	OPAQUE_FLAGS_OFF  => 8184,    # BLCKSZ - MAXALIGN(sizeof(BM25PageOpaqueData))
	BM25_POSTING      => (1 << 2),
	BM25_PENDING      => (1 << 3),
	BM25_BLOCK_SIZE   => 128,
	# block 0 metapage: contents at 24, then magic, version (uint32), ndocs,
	# sumdoclen (double), nsegments (uint32)
	META_NSEGMENTS_OFF => 24 + 24,
};

# Corrupt the on-disk index file (server must be DOWN).  Walks every 8 KB page,
# identifies posting/pending pages by their opaque flags, and injects the
# targeted count-overwrite + coarse content smash described above.  Returns a
# count of (posting pages hit, pending pages hit) so the caller can assert we
# actually found something to corrupt.
sub corrupt_index_file
{
	my ($path) = @_;
	open(my $fh, '+<:raw', $path) or die "open $path: $!";
	my $size = -s $fh;
	my ($posting_hits, $pending_hits) = (0, 0);

	for (my $base = 0; $base + BLCKSZ <= $size; $base += BLCKSZ)
	{
		# read the opaque flags and pd_lower for this page
		my $buf;
		sysseek($fh, $base + OPAQUE_FLAGS_OFF, 0) or die "seek: $!";
		sysread($fh, $buf, 2) == 2 or last;
		my $flags = unpack('v', $buf);

		sysseek($fh, $base + PD_LOWER_OFF, 0) or die "seek: $!";
		sysread($fh, $buf, 2) == 2 or last;
		my $pd_lower = unpack('v', $buf);

		# only touch used content; nothing to smash on an empty page
		next if $pd_lower <= CONTENT_START;
		my $content_len = $pd_lower - CONTENT_START;

		if ($flags & BM25_POSTING)
		{
			# TARGETED: first uint32 at content start is the first block's
			# `count`; set it far above BM25_BLOCK_SIZE to drive the clamp.
			sysseek($fh, $base + CONTENT_START, 0) or die "seek: $!";
			syswrite($fh, pack('V', 0xFFFF)) == 4 or die "write: $!";

			# COARSE: 0xFF a run in the middle of the used content -- guaranteed
			# to hit FOR-column bytes and later block headers' byte lengths.
			my $smash_off = CONTENT_START + int($content_len / 4);
			my $smash_len = int($content_len / 2);
			$smash_len = 64 if $smash_len > 64;    # keep it a torn *region*, not the whole page
			if ($smash_len > 0)
			{
				sysseek($fh, $base + $smash_off, 0) or die "seek: $!";
				syswrite($fh, ("\xFF" x $smash_len)) == $smash_len
				  or die "write: $!";
			}
			$posting_hits++;
		}
		elsif ($flags & BM25_PENDING)
		{
			# Smash the pending item's ftsdoc bytes (after the item header) so
			# fts_doc_is_valid rejects it on both the scan and the flush path.
			my $smash_off = CONTENT_START + 8;     # past tid+doclen of first item
			my $smash_len = $content_len - 8;
			$smash_len = 96 if $smash_len > 96;
			if ($smash_len > 0)
			{
				sysseek($fh, $base + $smash_off, 0) or die "seek: $!";
				syswrite($fh, ("\xFF" x $smash_len)) == $smash_len
				  or die "write: $!";
			}
			$pending_hits++;
		}
	}
	close($fh) or die "close $path: $!";
	return ($posting_hits, $pending_hits);
}

my $node = PostgreSQL::Test::Cluster->new('primary');
# no_data_checksums: this test injects torn bytes to exercise pg_fts's OWN
# decode-path hardening (bm25_decode_term / fts_doc_is_valid cast raw on-disk
# bytes to C structs and must survive).  PostgreSQL 18's initdb turns data
# checksums ON by default (PG<=17 defaulted them OFF); with checksums on, the
# smashed page fails PG's page-checksum verification in ReadBuffer and the read
# ERRORs ("invalid page in block N") BEFORE pg_fts's decoder ever sees the
# bytes -- so the query aborts (rc!=0) instead of returning a bounded-miss
# count, hiding the very code path this test targets.  Disabling checksums lets
# the torn bytes reach pg_fts's decoder exactly as they do on PG17, which is
# what these assertions were written to verify.  (no_data_checksums is a PG18+
# init param; PG<=17's harness ignores the unknown key -- checksums are already
# off there.)  PG's page-checksum gate is a separate defense layer; pg_fts's
# in-decoder hardening is what must hold when a torn page does reach it.
$node->init(no_data_checksums => 1);
# fsync off: the test never relies on durability, only on the page bytes we
# write while the server is down being what the server reads on restart.
$node->append_conf('postgresql.conf', "fsync = off\n");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_fts');

# Build an index whose posting lists span MANY 128-doc blocks: 'common' is in
# every one of 4000 rows (df=4000 -> ~32 blocks) and 'alpha beta' is a phrase
# so positions are decoded across block boundaries.  positions=on so the
# posbytelen path is exercised too.  VACUUM + fts_merge flush the pending
# write buffer into on-disk segment postings, which is what bm25_decode_term
# reads.
$node->safe_psql(
	'postgres', q{
	CREATE TABLE docs (id int, body text);
	CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body))
		WITH (positions = on);
	INSERT INTO docs
		SELECT g, 'alpha beta common tok' || (g % 200)
		FROM generate_series(1, 4000) g;
	VACUUM docs;
	SELECT fts_merge('docs_fts');
});

# Add rows AFTER the merge so they land in the pending write buffer (a pending
# page on disk), to be corrupted and exercise fts_doc_is_valid.
$node->safe_psql(
	'postgres', q{
	INSERT INTO docs
		SELECT g, 'gamma delta pending doc ' || g
		FROM generate_series(9000, 9200) g;
});

my $q = "SET enable_seqscan=off;";

# Pre-corruption sanity: the index answers, and a whole-corpus term exists.
my $common_before = $node->safe_psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery");
is($common_before, 4000, 'pre-corruption: common found in all 4000 built rows');

my $relpath = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('docs_fts')");
ok(defined $relpath && length $relpath, "located index relfile: $relpath");

# Corrupt with the server DOWN, then bring it back up: recovery replays no
# WAL for our hand-written bytes, so the server reads exactly the torn image.
$node->stop;
my $abs = $node->data_dir . '/' . $relpath;
ok(-f $abs, "index file exists on disk: $abs");
my ($ph, $pn) = corrupt_index_file($abs);
ok($ph > 0, "corrupted at least one posting page (targeted + coarse); hit $ph");
# pending pages may or may not be present depending on flush timing; report it.
diag("corrupted $ph posting page(s), $pn pending page(s)");
$node->start;

# ---- The crux: the backend must SURVIVE scans/VACUUM over the torn index. ----

# A scan over the corrupted posting lists must return through a LIVE
# connection -- not "server closed the connection unexpectedly".  We do not
# assert the count value (a corrupt block is a bounded miss and may drop
# postings); we assert the query completes without crashing the backend.
my ($rc, $stdout, $stderr) = $node->psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery");
is($rc, 0, 'scan over corrupted posting blocks did not crash the backend');
unlike($stderr, qr/server closed the connection unexpectedly|terminating connection/,
	'no connection loss on corrupted-posting scan');
like($stdout, qr/^\d+$/, 'corrupted-posting scan returned a sane integer count');

# A phrase scan decodes positions across block boundaries -- the posbytelen
# path -- over the same corrupted blocks.  Must also survive.
($rc, $stdout, $stderr) = $node->psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ '\"alpha beta\"'::ftsquery");
is($rc, 0, 'phrase scan (positions decode) over corrupted blocks did not crash');
unlike($stderr, qr/server closed the connection unexpectedly|terminating connection/,
	'no connection loss on corrupted-posting phrase scan');

# A scan that must read the corrupted PENDING page (gamma/delta live only in
# the pending buffer) must skip the malformed doc, not segfault.
($rc, $stdout, $stderr) = $node->psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'gamma'::ftsquery");
is($rc, 0, 'scan over corrupted pending page did not crash the backend');
unlike($stderr, qr/server closed the connection unexpectedly|terminating connection/,
	'no connection loss on corrupted-pending scan');

# VACUUM triggers a pending-list FLUSH (bm25_flush_pending) and touches the
# posting decoder -- the reporter's other crash path.  Must complete.
($rc, $stdout, $stderr) = $node->psql('postgres', 'VACUUM docs');
is($rc, 0, 'VACUUM (pending flush + decode) over corrupted index did not crash');
unlike($stderr, qr/server closed the connection unexpectedly|terminating connection/,
	'no connection loss during VACUUM of corrupted index');

# The cluster is still fully alive and can serve an ordinary connection and a
# normal (non-corrupt) query afterwards.
$node->connect_ok('dbname=postgres', 'cluster still accepts connections after corruption');
my $alive = $node->safe_psql('postgres', 'SELECT 1');
is($alive, 1, 'backend healthy after corruption + scans + VACUUM');

# Corruption should have been REPORTED (not silently), matching the fix's
# WARNING contract.  We accept either the segment-decode or the pending-doc
# warning (which one fires depends on which corrupted page a query reaches).
# This is a soft check: the hard guarantee is "no crash" above.
my $log = slurp_file($node->logfile);
my $warned = ($log =~ /truncated posting block/)
	|| ($log =~ /skipping malformed pending document/);
ok($warned, 'server logged a corruption WARNING (truncated posting block / malformed pending document)');

# REINDEX must rebuild a clean index from the heap and restore correct answers,
# proving corruption is recoverable, not terminal.
$node->safe_psql('postgres', 'REINDEX INDEX docs_fts');
my $common_after = $node->safe_psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery");
is($common_after, 4000, 'REINDEX from heap restores correct answers after corruption');

# ---------------------------------------------------------------------------
# A corrupt TOMBSTONE blob must be a loud error, never a silent resurrection.
#
# sparsemap 5.6.0 hardened sm_open(): a buffer that fails validation is silently
# replaced with an EMPTY map (void return, no errno).  For a general library taking
# untrusted bytes that is correct.  For a tombstone map it would mean "nothing is
# deleted" -- every vacuumed document reappears in query results with no error, the
# exact plausible-wrong-answer failure this project refuses.  pg_fts therefore checks
# the reopened size against the stored length (they are equal for any blob we wrote)
# and raises ERRCODE_DATA_CORRUPTED instead.  This case would pass on 5.5.1 only by
# accident (garbage offsets, likely a crash) and fails on 5.6.0 without the guard,
# because the count comes back as if nothing had been deleted.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres', q{
	DELETE FROM docs WHERE id % 2 = 0;
	VACUUM docs;                 -- bulkdelete records 2000 tombstones into a livedocs blob
});
my $live_before = $node->safe_psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery");
is($live_before, 2000, 'after deleting half: tombstones hide 2000 of 4000 (pre-corruption)');

# REINDEX above gave the index a NEW relfilenode; the earlier $abs is stale.
my $relpath2 = $node->safe_psql('postgres', "SELECT pg_relation_filepath('docs_fts')");
my $abs2 = $node->data_dir . '/' . $relpath2;
$node->stop;
ok(-f $abs2, "re-resolved index file after REINDEX: $abs2");
{
	# Smash the CONTENTS of every blob page, leaving the page header and opaque intact
	# so the chain is still followed and read; only the sparsemap bytes inside are
	# garbage.  The tombstone blob is written by bm25_write_blob(), which stamps its
	# pages BM25_TRGM_DATA (1<<5) -- the same page type as a trigram blob, because
	# both are "opaque serialized sparsemap" pages.  This index was built with
	# trigrams OFF (the default), so every TRGM_DATA page here IS the tombstone blob.
	# (BM25_LIVEDOCS (1<<6) exists in the header but nothing writes it.)
	my $LIVEDOCS = (1 << 5);
	open(my $fh, '+<:raw', $abs2) or die "open $abs2: $!";
	my $size = -s $fh;
	my $hits = 0;
	for (my $base = 0; $base + BLCKSZ <= $size; $base += BLCKSZ)
	{
		my $buf;
		sysseek($fh, $base + OPAQUE_FLAGS_OFF, 0) or die;
		sysread($fh, $buf, 2) == 2 or die;
		my $flags = unpack('v', $buf);
		next unless $flags & $LIVEDOCS;
		sysseek($fh, $base + CONTENT_START, 0) or die;
		syswrite($fh, "\xA5" x 256) == 256 or die;
		$hits++;
	}
	close $fh;
	ok($hits > 0, "corrupted $hits tombstone (livedocs) page(s)");
}
$node->start;

my ($trc, $tout, $terr) = $node->psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery");
isnt($trc, 0, 'a scan over a corrupt tombstone blob ERRORS rather than answering');
like($terr, qr/corrupt tombstone bitmap/,
	 'the error names the corrupt tombstone bitmap (not a generic failure)');
unlike($tout, qr/^\s*4000\s*$/,
	 'and it did NOT silently return 4000 (the resurrected-deletes answer)');

# Recoverable, as before.
$node->safe_psql('postgres', 'REINDEX INDEX docs_fts');
my $live_after = $node->safe_psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery");
is($live_after, 2000, 'REINDEX restores the correct 2000 after tombstone corruption');

# ---------------------------------------------------------------------------
# A metapage that lists more segments than its directory holds (128) must be a
# clean ERRCODE_INDEX_CORRUPTED error, raised before any reader indexes segs[]
# with it (1.14.1).  Before, every reader looped `s < nsegments` over the
# fixed-size array: an out-of-bounds read of whatever followed it.
# ---------------------------------------------------------------------------
my $relpath3 = $node->safe_psql('postgres', "SELECT pg_relation_filepath('docs_fts')");
my $abs3 = $node->data_dir . '/' . $relpath3;
$node->stop;
{
	open(my $fh, '+<:raw', $abs3) or die "open $abs3: $!";
	my $buf;
	sysseek($fh, META_NSEGMENTS_OFF, 0) or die;
	sysread($fh, $buf, 4) == 4 or die;
	my $nseg = unpack('V', $buf);
	ok($nseg >= 1 && $nseg <= 128, "metapage nsegments is $nseg before corruption");
	sysseek($fh, META_NSEGMENTS_OFF, 0) or die;
	syswrite($fh, pack('V', 100000)) == 4 or die;
	close $fh;
}
$node->start;
my ($mrc, $mout, $merr) = $node->psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery");
isnt($mrc, 0, 'a query over a metapage listing 100000 segments ERRORS');
like($merr, qr/metapage is corrupt: it lists 100000 segments/,
	 'the error names the impossible segment count');
my ($vrc, $vout, $verr) = $node->psql('postgres', 'VACUUM docs');
like($verr, qr/metapage is corrupt/, 'VACUUM reports the same corruption');
$node->safe_psql('postgres', 'REINDEX INDEX docs_fts');
is($node->safe_psql('postgres',
	"$q SELECT count(*) FROM docs WHERE to_ftsdoc('simple', body) \@\@\@ 'common'::ftsquery"),
	2000, 'REINDEX restores the correct 2000 after metapage corruption');

# ---------------------------------------------------------------------------
# A posting block whose FOR width byte is corrupt while its count and lengths
# are intact (CHANGELOG 1.16.0, found by test/cbmc ondisk_harness).  The
# ranked loader (wand_load_block) checked only that the block fits the page and
# then decoded columns sized by their width bytes.  Width 9 on a full block at
# width 8 still fits the docid column inside bytelen, so the old loader decoded
# garbage docids from the block's own bytes (deterministically) and the ranked
# answer disagreed with count(*), or failed: an assertion failure in an
# assert-enabled build, "could not read blocks" otherwise.  Width 64 reads past
# the block.  Now the block ends the cursor's chain -- a bounded miss, as
# count(*)'s decoder already made it -- and both paths agree.
# ---------------------------------------------------------------------------
$node->safe_psql(
	'postgres', q{
	CREATE TABLE wb (id int, d ftsdoc);
	INSERT INTO wb SELECT g, to_ftsdoc('simple', 'alpha beta' || (g % 7))
		FROM generate_series(1, 5000) g;
	CREATE INDEX wb_fts ON wb USING fts (d);
	CHECKPOINT;
});
my $wq = "$q SELECT count(*) FROM (SELECT id FROM wb WHERE d \@\@\@ 'alpha'::ftsquery"
  . " ORDER BY d <=> 'alpha'::ftsquery LIMIT 6000) s";
my $wc = "$q SELECT count(*) FROM wb WHERE d \@\@\@ 'alpha'::ftsquery";
is($node->safe_psql('postgres', $wq), 5000, 'width-byte: ranked finds all 5000 before corruption');
my $relpath4 = $node->safe_psql('postgres', "SELECT pg_relation_filepath('wb_fts')");
my $abs4 = $node->data_dir . '/' . $relpath4;
foreach my $width (9, 64)
{
	$node->stop;
	my $wb_hit = 0;
	{
		open(my $fh, '+<:raw', $abs4) or die "open $abs4: $!";
		my $size = -s $fh;
		for (my $base = 0; $base + BLCKSZ <= $size && !$wb_hit; $base += BLCKSZ)
		{
			my $buf;
			sysseek($fh, $base + OPAQUE_FLAGS_OFF, 0) or die;
			sysread($fh, $buf, 2) == 2 or die;
			next unless unpack('v', $buf) & BM25_POSTING;
			sysseek($fh, $base + CONTENT_START, 0) or die;
			sysread($fh, $buf, 29) == 29 or die;
			my ($cnt, $mtf, $mdl, $hi, $lo, $bytelen, $posb, $w) = unpack('V7C', $buf);
			# alpha's first block: full, docid column at width 8
			next unless $cnt == 128 && $w == 8 && $bytelen < 1025;
			# the docid column's width byte follows the 28-byte block header
			sysseek($fh, $base + CONTENT_START + 28, 0) or die;
			syswrite($fh, pack('C', $width)) == 1 or die;
			$wb_hit = 1;
		}
		close $fh;
	}
	ok($wb_hit, "width-byte $width: corrupted the docid width byte of alpha's first block");
	$node->start;
	my ($wrc, $wout, $werr) = $node->psql('postgres', $wq);
	is($wrc, 0, "width-byte $width: the ranked query returns without an error");
	my ($crc, $cout) = $node->psql('postgres', $wc);
	is($crc, 0, "width-byte $width: count(*) returns without an error");
	is($wout, $cout, "width-byte $width: ranked and count(*) agree (both a bounded miss)");
	is($node->safe_psql('postgres', 'SELECT 1'), 1, "width-byte $width: the server is still up");
	$node->safe_psql('postgres', 'REINDEX INDEX wb_fts');
	is($node->safe_psql('postgres', $wq), 5000, "width-byte $width: REINDEX restores all 5000");
	$relpath4 = $node->safe_psql('postgres', "SELECT pg_relation_filepath('wb_fts')");
	$abs4 = $node->data_dir . '/' . $relpath4;
}

# ---------------------------------------------------------------------------
# A segment with two-column postings and no doclen sidecar: what 1.5.0-1.5.2's
# merge wrote (CHANGELOG 1.5.3).  The ranked loader took the column count from
# the segment (no sidecar => three columns) and read a "doclen" past the copied
# block.  Recreate the layout by clearing segs[0].doclenstart in the metapage
# of an index whose postings are two-column; the ranked query must return every
# match, without an error, as count(*) (which detects the columns per block)
# always did.
# ---------------------------------------------------------------------------
$node->safe_psql(
	'postgres', q{
	CREATE TABLE v2c (id int, d ftsdoc);
	INSERT INTO v2c SELECT g, to_ftsdoc('simple', 'kappa lambda' || (g % 5))
		FROM generate_series(1, 3000) g;
	CREATE INDEX v2c_fts ON v2c USING fts (d);
	CHECKPOINT;
});
my $vq = "$q SELECT count(*) FROM (SELECT id FROM v2c WHERE d \@\@\@ 'kappa'::ftsquery"
  . " ORDER BY d <=> 'kappa'::ftsquery LIMIT 4000) s";
is($node->safe_psql('postgres', $vq), 3000, 'two-column v3: ranked finds all 3000 with a sidecar');
my $relpath5 = $node->safe_psql('postgres', "SELECT pg_relation_filepath('v2c_fts')");
my $abs5 = $node->data_dir . '/' . $relpath5;
$node->stop;
{
	# BM25MetaPageData: contents at 24; segs[] at 40; BM25SegMeta is 56 bytes
	# with doclenstart at 48 (so segs[0].doclenstart is page byte 112)
	open(my $fh, '+<:raw', $abs5) or die "open $abs5: $!";
	my $buf;
	sysseek($fh, META_NSEGMENTS_OFF, 0) or die;
	sysread($fh, $buf, 4) == 4 or die;
	is(unpack('V', $buf), 1, 'two-column v3: one segment');
	sysseek($fh, 112, 0) or die;
	sysread($fh, $buf, 4) == 4 or die;
	isnt(unpack('V', $buf), 0xFFFFFFFF, 'two-column v3: the segment has a sidecar before');
	sysseek($fh, 112, 0) or die;
	syswrite($fh, pack('V', 0xFFFFFFFF)) == 4 or die;
	close $fh;
}
$node->start;
my ($vrc2, $vout2, $verr2) = $node->psql('postgres', $vq);
is($vrc2, 0, 'two-column v3: the ranked query returns without an error');
is($vout2, 3000, 'two-column v3: ranked still finds all 3000');
is($node->safe_psql('postgres', "$q SELECT count(*) FROM v2c WHERE d \@\@\@ 'kappa'::ftsquery"),
	3000, 'two-column v3: count(*) agrees');
$node->safe_psql('postgres', 'REINDEX INDEX v2c_fts');

$node->stop;
done_testing();
