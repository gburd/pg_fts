#!/bin/bash
# pg_fts 1.14.1 gate (round 2) on b3: PG 17.10 (/nvme/pg17) + 18.6 (/nvme/pg18), tree = /nvme/b3/final_r2.tgz.
# Writes /nvme/b3/gate141.log.  Each major gets its own fresh tree (make clean between majors).
set -uo pipefail
exec > /nvme/b3/gate141r2.log 2>&1
for M in 17 18; do
  B=/nvme/pg$M/bin; PGSRC=$(ls -d /nvme/postgresql-$M.*)
  T=/nvme/b3/gtree$M; [ -d $T ] && mv $T /nvme/trash_g_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/final_r2.tgz -C $T; cd $T
  echo "== PG$M $($B/postgres --version) tree $(cat GITREV 2>/dev/null) $(grep default_version pg_fts.control) markers: $(grep -c 'BM25_BULKDELETE_BATCH_MAX\|bm25_query_segdf\|bm25_check_nsegments\|fts_rel_bm25_index\|meta.npending)' pg_fts_am.c pg_fts_am_scan.c pg_fts_customscan.c | tr '\n' ' ')"
  make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1
  make -s PG_CONFIG=$B/pg_config -j32 2>&1 | grep -E "warning:|error:" | head; make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
  echo "installed so md5 $(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8); ext files: $(ls $($B/pg_config --sharedir)/extension/pg_fts--1.14.1.sql $($B/pg_config --sharedir)/extension/pg_fts--1.14.0--1.14.1.sql | wc -l)"
  D=/nvme/b3/grg$M; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_g_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=556$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=512MB\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  echo "== PG$M regress+isolation"
  make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=556$M PGUSER=postgres PROVE_TESTS=ci/noop.pl > /nvme/b3/gate141r2-ic$M.log 2>&1; echo "installcheck rc=$?"
  grep -E "^(ok|not ok) " /nvme/b3/gate141r2-ic$M.log | awk '{print $1,$2,$4}' | tr '\n' ';'; echo
  echo "summary: $(grep -cE '^ok ' /nvme/b3/gate141r2-ic$M.log) ok, $(grep -cE '^not ok ' /nvme/b3/gate141r2-ic$M.log) not ok; $(grep -E 'tests passed|tests failed|All [0-9]+ tests' /nvme/b3/gate141r2-ic$M.log | tr '\n' ' ')"
  for f in regression.diffs output_iso/regression.diffs; do [ -f $f ] && { echo "== PG$M $f (head)"; head -60 $f; }; done
  echo "== PG$M query_binary: $(PATH=$B:$PATH PGHOST=/tmp PGPORT=556$M PGUSER=postgres python3 test/query_binary.py --local 2>&1 | tail -1)"
  $B/pg_ctl -D $D -w stop >/dev/null
  echo "== PG$M tap"
  mv tmp_check /nvme/trash_g_$RANDOM 2>/dev/null
  make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= \
    PROVE_TESTS='t/003_corruption.pl t/004_encodings.pl t/005_concurrency.pl t/006_concurrent_extend.pl t/007_segment_cap.pl t/008_vacuum_reclaim.pl t/010_vacuum_delete_heavy.pl t/011_shared_doclen.pl t/012_concurrent_flush.pl' > /nvme/b3/gate141r2-tap$M.log 2>&1; echo "tap rc=$?"
  grep -E "^t/.*(ok|FAIL|Dubious|skipped)|^Result|^Files=|Failed" /nvme/b3/gate141r2-tap$M.log | tail -16
done
cd /nvme/b3/gtree17
echo "== check-alloc: $(bash ci/check-alloc.sh 2>&1 | tail -1)"
echo "== check-ascii: $(make -s check-ascii PG_CONFIG=/nvme/pg17/bin/pg_config 2>&1 | tail -1) rc=$?"
echo "== fuzz"; bash test/fuzz/run.sh > /nvme/b3/gate141r2-fuzz.log 2>&1; echo "fuzz rc=$?"; grep -E "^PASS|^FAIL|ALL CLEAN" /nvme/b3/gate141r2-fuzz.log | tail -14
for i in 1 2 3; do mv tmp_check /nvme/trash_g_$RANDOM 2>/dev/null; echo "== t012 rerun $i (PG17): $(make PG_CONFIG=/nvme/pg17/bin/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/012_concurrent_flush.pl 2>&1 | grep -E '^Result|Failed test|^t/' | tr '\n' ' ')"; done
echo "== oom: $(sudo dmesg | grep -c 'Out of memory')"
echo GATE141_DONE
