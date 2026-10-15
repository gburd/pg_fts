#!/bin/bash
# pg_fts gate on a fresh Debian 13 EC2 host (user admin): XFS on the local NVMe,
# PostgreSQL 17.10 + 18.x from source (tap tests on, cassert off), then for each
# major: fuzz, regress + isolation (installcheck), every TAP test, query_binary.py,
# ci/check-alloc.sh, make check-ascii.  Writes /nvme/gate13.log.
set -uo pipefail
exec > /nvme/gate13.log 2>&1 || exec > /tmp/gate13.log 2>&1
cd /nvme
for v in 17.10 18.1; do
  [ -x /nvme/pg${v%%.*}/bin/postgres ] && continue
  curl -sfLO https://ftp.postgresql.org/pub/source/v$v/postgresql-$v.tar.bz2 || { echo "NO_PG_$v"; continue; }
  tar xjf postgresql-$v.tar.bz2; (cd postgresql-$v && ./configure --prefix=/nvme/pg${v%%.*} --enable-tap-tests \
     CFLAGS="-O2 -g -fno-omit-frame-pointer" >/nvme/cfg$v.log 2>&1 && make -s -j$(nproc) >/nvme/mk$v.log 2>&1 && make -s install >/dev/null \
     && for c in pg_prewarm pg_buffercache fuzzystrmatch pageinspect; do (cd contrib/$c && make -s install >/dev/null); done)
  echo "PG $v built: $(/nvme/pg${v%%.*}/bin/postgres --version)"
done
for M in 17 18; do
  B=/nvme/pg$M/bin; [ -x $B/postgres ] || { echo "== PG$M missing"; continue; }
  T=/nvme/tree$M; [ -d $T ] && mv $T $T.old.$$; mkdir -p $T; tar xzf /tmp/fts_tree.tgz -C $T; cd $T
  echo "== PG$M tree $(cat GITREV 2>/dev/null) $(grep default_version pg_fts.control)"
  make -s PG_CONFIG=$B/pg_config -j$(nproc) 2>&1 | grep -E "warning:|error:" | head; make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
  D=/nvme/rg$M; [ -d $D ] && mv $D $D.old.$$; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=554$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=512MB\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  echo "== PG$M regress+isolation"; make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=554$M PGUSER=postgres PROVE_TESTS=ci/noop.pl 2>&1 | grep -E "^(ok|not ok)|tests passed|failed" | awk '{print $1,$2,$4,$5,$6}' | tr '\n' ';'; echo
  [ -f regression.diffs ] && { echo "== PG$M regression.diffs (head)"; head -60 regression.diffs; }
  echo "== PG$M query_binary"; PATH=$B:$PATH PGHOST=/tmp PGPORT=554$M PGUSER=postgres python3 test/query_binary.py --local 2>&1 | tail -1
  $B/pg_ctl -D $D -w stop >/dev/null
  echo "== PG$M tap"; make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= 2>&1 | grep -E "^t/.*(ok|FAIL|Dubious)|^Result|^Files=|Failed" | tail -16
done
cd /nvme/tree17
echo "== check-alloc: $(bash ci/check-alloc.sh 2>&1 | tail -1)"
echo "== check-ascii: $(make -s check-ascii 2>&1 | tail -1)"
echo "== fuzz"; bash test/fuzz/run.sh 2>&1 | grep -E "^PASS|^FAIL|ALL CLEAN" | tail -12
echo GATE13_MAIN_DONE
# extra: t/012 three more times on PG17 (it is the concurrency regression test)
cd /nvme/tree17; for i in 1 2 3; do echo "== t012 rerun $i: $(make PG_CONFIG=/nvme/pg17/bin/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/012_concurrent_flush.pl 2>&1 | grep -E '^Result|Failed test' | tr '\n' ' ')"; done
echo "== oom: $(sudo dmesg | grep -c 'Out of memory')"
echo GATE13B_DONE
