#!/bin/bash
# pg_fts 1.14.3 gate on iss: PG 17.10 (/nvme/pg17) + 18.6 (/nvme/pg18), tree = /nvme/iss/gate/final.tgz.
# Adapted from bench/data_1142_2026-10-25/scripts/gate142.sh.  Each major gets its own prefix copy.
set -uo pipefail
G=/nvme/iss/gate; mkdir -p $G
exec > $G/gate143.log 2>&1
for M in 17 18; do
  PFX=$G/pfx$M; [ -d $PFX ] || cp -a /nvme/pg$M $PFX
  B=$PFX/bin
  T=$G/gtree$M; [ -d $T ] && mv $T /nvme/trash_g_$RANDOM; mkdir -p $T; tar xzf $G/final.tgz -C $T; cd $T
  echo "== PG$M $($B/postgres --version) tree $(cat GITREV) $(grep default_version pg_fts.control) REGRESS: $(grep -c 'planner_partial ranked_empty_and' Makefile) bool_gate_may_admit in source: $(grep -c bool_gate_may_admit pg_fts_am_scan.c)"
  make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1
  make -s PG_CONFIG=$B/pg_config -j32 2>&1 | grep -E "warning:|error:" | head; make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
  echo "installed so md5 $(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8); ext files: $(ls $($B/pg_config --sharedir)/extension/pg_fts--1.14.3.sql $($B/pg_config --sharedir)/extension/pg_fts--1.14.2--1.14.3.sql | wc -l); stale 1.14.2 base: $(ls $($B/pg_config --sharedir)/extension/pg_fts--1.14.2.sql 2>/dev/null | wc -l) (copied prefix had none: fresh /nvme/pg$M copy)"
  D=$G/grg$M; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_g_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=596$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=512MB\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  echo "== PG$M regress+isolation"
  make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=596$M PGUSER=postgres PROVE_TESTS=ci/noop.pl > $G/ic$M.log 2>&1; echo "installcheck rc=$?"
  grep -E "^(ok|not ok) " $G/ic$M.log | awk '{print $1,$2,$4}' | tr '\n' ';'; echo
  echo "summary: $(grep -cE '^ok ' $G/ic$M.log) ok, $(grep -cE '^not ok ' $G/ic$M.log) not ok; $(grep -E 'tests passed|tests failed|All [0-9]+ tests' $G/ic$M.log | tr '\n' ' ')"
  for f in regression.diffs output_iso/regression.diffs; do [ -f $f ] && { echo "== PG$M $f (head)"; head -60 $f; }; done
  echo "== PG$M query_binary: $(PATH=$B:$PATH PGHOST=/tmp PGPORT=596$M PGUSER=postgres python3 test/query_binary.py --local 2>&1 | tail -1)"
  $B/pg_ctl -D $D -w stop >/dev/null
  echo "== PG$M tap"
  mv tmp_check /nvme/trash_g_$RANDOM 2>/dev/null
  make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= \
    PROVE_TESTS='t/003_corruption.pl t/004_encodings.pl t/005_concurrency.pl t/006_concurrent_extend.pl t/007_segment_cap.pl t/008_vacuum_reclaim.pl t/010_vacuum_delete_heavy.pl t/011_shared_doclen.pl t/012_concurrent_flush.pl' > $G/tap$M.log 2>&1; echo "tap rc=$?"
  grep -E "^t/.*(ok|FAIL|Dubious|skipped)|^Result|^Files=|Failed" $G/tap$M.log | tail -16
done
cd $G/gtree17
echo "== check-alloc: $(bash ci/check-alloc.sh 2>&1 | tail -1) rc=$?"
echo "== check-ascii: $(make -s check-ascii PG_CONFIG=$G/pfx17/bin/pg_config 2>&1 | tail -1) rc=$?"
echo "== fuzz"; bash test/fuzz/run.sh > $G/fuzz.log 2>&1; echo "fuzz rc=$?"; grep -E "^PASS|^FAIL|ALL CLEAN" $G/fuzz.log | tail -14
for i in 1 2 3; do mv tmp_check /nvme/trash_g_$RANDOM 2>/dev/null; echo "== t012 rerun $i (PG17): $(make PG_CONFIG=$G/pfx17/bin/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/012_concurrent_flush.pl 2>&1 | grep -E '^Result|Failed test|^t/' | tr '\n' ' ')"; done
echo "== oom: $(sudo dmesg | grep -c 'Out of memory')"
echo GATE143_DONE
