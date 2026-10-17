#!/bin/bash
# per-commit: build on PG18 into its own prefix and run REGRESS+ISOLATION (installcheck)
set -uo pipefail
for c in 17e8d8a 86b7edb a75c44f 1234af2; do
  PFX=/nvme/b3/pc-$c; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
  T=/nvme/b3/pct-$c; [ -d $T ] && mv $T /nvme/trash_pc_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/c-$c.tgz -C $T; cd $T
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j16 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
  D=/nvme/b3/pcd-$c; [ -d $D ] && mv $D /nvme/trash_pc_$RANDOM; $PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  P=$((55800 + RANDOM % 100)); printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  make PG_CONFIG=$PFX/bin/pg_config installcheck PGHOST=/tmp PGPORT=$P PGUSER=postgres PROVE_TESTS=ci/noop.pl > /nvme/b3/pc-$c.log 2>&1; rc=$?
  echo "$c rc=$rc $(grep -cE '^ok ' /nvme/b3/pc-$c.log) ok $(grep -cE '^not ok ' /nvme/b3/pc-$c.log) not-ok: $(grep -E '^not ok' /nvme/b3/pc-$c.log | awk '{print $4}' | tr '\n' ' ')"
  $PFX/bin/pg_ctl -D $D -w stop >/dev/null
done
echo PERCOMMIT_DONE
