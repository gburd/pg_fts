#!/bin/bash
# gate150.sh: pg_fts 1.15.0 release gate on one host, PG 17.10 (/nvme/pg17) + 18.6 (/nvme/pg18),
# tree = /nvme/g150/final.tgz (git archive of the release commit + GITREV).  Per major, in its own prefix copy:
# build (warnings listed), installcheck (all REGRESS + ISOLATION), query_binary.py, TAP (12 files, normal build:
# t/014 t/015 must SKIP), then a -DPG_FTS_TEST_HOOKS build with PG_FTS_TEST_HOOKS_BUILD=1 running t/014 + t/015
# (must PASS, as the CI step).  Then check-alloc, check-ascii, fuzz, docs (xmllint), 3 t/012 + 3 t/013 reruns.
set -uo pipefail
G=/nvme/g150; mkdir -p $G
exec > $G/gate150.log 2>&1
TAPS='t/003_corruption.pl t/004_encodings.pl t/005_concurrency.pl t/006_concurrent_extend.pl t/007_segment_cap.pl t/008_vacuum_reclaim.pl t/010_vacuum_delete_heavy.pl t/011_shared_doclen.pl t/012_concurrent_flush.pl t/013_ranked_flush_race.pl t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl'
for M in 17 18; do
  PFX=$G/pfx$M; [ -d $PFX ] || cp -a /nvme/pg$M $PFX
  B=$PFX/bin
  T=$G/gtree$M; [ -d $T ] && mv $T /nvme/trash_g_$RANDOM; mkdir -p $T; tar xzf $G/final.tgz -C $T; cd $T
  echo "== PG$M $($B/postgres --version) tree $(cat GITREV) $(grep default_version pg_fts.control); markers: driven=$(grep -c fts_search_driven pg_fts_am_scan.c) pendclear=$(grep -c BM25PendingClear pg_fts_am.c) partialcount=$(grep -c fts_rel_partial_count_index pg_fts_customscan.c) chunk=$(grep -c FTS_PARSE_CHUNK pg_fts_tsanalyze.c) c4018=$(grep -c '<= (int) it->distance' pg_fts_match.c pg_fts_am_scan.c | tr '\n' ' ')"
  make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1
  make -s PG_CONFIG=$B/pg_config -j32 2>&1 | grep -E "warning:|error:" | head; make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
  echo "installed so md5 $(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8); ext files: $(ls $($B/pg_config --sharedir)/extension/pg_fts--1.15.0.sql $($B/pg_config --sharedir)/extension/pg_fts--1.14.3--1.15.0.sql | wc -l); stale 1.14.3 base in tree: $(ls pg_fts--1.14.3.sql 2>/dev/null | wc -l); test-hook symbols in normal .so: $(nm -D $($B/pg_config --pkglibdir)/pg_fts.so 2>/dev/null | grep -c test_ ; strings $($B/pg_config --pkglibdir)/pg_fts.so | grep -c 'pg_fts.test_')"
  D=$G/grg$M; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_g_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=596$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=512MB\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  echo "== PG$M regress+isolation"
  make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=596$M PGUSER=postgres PROVE_TESTS=ci/noop.pl > $G/ic$M.log 2>&1; echo "installcheck rc=$?"
  grep -E "^(ok|not ok) " $G/ic$M.log | awk '{print $1,$2,$4}' | tr '\n' ';'; echo
  echo "summary: $(grep -cE '^ok ' $G/ic$M.log) ok, $(grep -cE '^not ok ' $G/ic$M.log) not ok; REGRESS in Makefile: $(sed -n 's/^REGRESS = //p' Makefile | wc -w); ISOLATION: $(sed -n 's/^ISOLATION = //p' Makefile | wc -w)"
  for f in regression.diffs output_iso/regression.diffs; do [ -f $f ] && { echo "== PG$M $f (head)"; head -60 $f; }; done
  echo "== PG$M query_binary: $(PATH=$B:$PATH PGHOST=/tmp PGPORT=596$M PGUSER=postgres python3 test/query_binary.py --local 2>&1 | tail -1)"
  $B/pg_ctl -D $D -w stop >/dev/null
  echo "== PG$M tap (normal build)"
  mv tmp_check /nvme/trash_g_$RANDOM 2>/dev/null
  make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS="$TAPS" > $G/tap$M.log 2>&1; echo "tap rc=$?"
  grep -E "^t/.*(ok|FAIL|Dubious|skipped)|^Result|^Files=|Failed" $G/tap$M.log | tail -16
  echo "== PG$M tap (hooks build, PG_FTS_TEST_HOOKS_BUILD=1)"
  HP=$G/pfxh$M; [ -d $HP ] || cp -a /nvme/pg$M $HP
  HT=$G/htree$M; [ -d $HT ] && mv $HT /nvme/trash_g_$RANDOM; mkdir -p $HT; tar xzf $G/final.tgz -C $HT; cd $HT
  make -s PG_CONFIG=$HP/bin/pg_config -j32 COPT=-DPG_FTS_TEST_HOOKS 2>&1 | grep -E "warning:|error:" | head; make -s PG_CONFIG=$HP/bin/pg_config install >/dev/null 2>&1
  echo "hooks so: $(strings $($HP/bin/pg_config --pkglibdir)/pg_fts.so | grep -c 'pg_fts.test_')"
  PG_FTS_TEST_HOOKS_BUILD=1 make PG_CONFIG=$HP/bin/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS='t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl' > $G/taph$M.log 2>&1; echo "hooks tap rc=$?"
  grep -E "^t/.*(ok|FAIL|Dubious|skipped)|^Result|^Files=|Failed" $G/taph$M.log | tail -6
  cd $T
done
cd $G/gtree17
echo "== check-alloc: $(bash ci/check-alloc.sh 2>&1 | tail -1) rc=$?"
echo "== check-ascii: $(make -s check-ascii PG_CONFIG=$G/pfx17/bin/pg_config 2>&1 | tail -1) rc=$?"
echo "== docs: xmllint $(xmllint --noout --noent doc/pg_fts.sgml 2>&1 | grep -c -i error) errors; $( [ -x doc/build-html.sh ] && (bash doc/build-html.sh > $G/docs.log 2>&1; echo "build-html rc=$? undefined-entity: $(grep -ci 'undefined entity' $G/docs.log)") || echo 'no build-html.sh')"
echo "== fuzz"; bash test/fuzz/run.sh > $G/fuzz.log 2>&1; echo "fuzz rc=$?"; grep -E "^PASS|^FAIL|ALL CLEAN" $G/fuzz.log | tail -14
for t in t/012_concurrent_flush.pl t/013_ranked_flush_race.pl; do for i in 1 2 3; do mv tmp_check /nvme/trash_g_$RANDOM 2>/dev/null; echo "== $t rerun $i (PG17): $(make PG_CONFIG=$G/pfx17/bin/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=$t 2>&1 | grep -E '^Result|Failed test|^t/' | tr '\n' ' ')"; done; done
echo "== coverage (ci/coverage.sh, COV_MIN=90 COV_CORPUS=1, PG17)"
CT=$G/covtree; [ -d $CT ] && mv $CT /nvme/trash_g_$RANDOM; mkdir -p $CT; tar xzf $G/final.tgz -C $CT; cd $CT
CP=$G/pfxcov; [ -d $CP ] || cp -a /nvme/pg17 $CP
COV_MIN=90 COV_CORPUS=1 PG_CONFIG=$CP/bin/pg_config PGBIN=$CP/bin bash ci/coverage.sh > $G/cov.log 2>&1; echo "coverage rc=$?"; tail -8 $G/cov.log
echo "== oom: $(sudo dmesg | grep -c 'Out of memory')"
echo GATE150_DONE
