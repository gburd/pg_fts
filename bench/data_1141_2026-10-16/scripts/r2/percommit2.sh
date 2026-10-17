#!/bin/bash
# per-commit (round 2): build each commit's tree on PG 18.6 into its own prefix, run REGRESS+ISOLATION installcheck
set -uo pipefail
for c in ${COMMITS}; do
  PFX=/nvme/b3/pc2-$c; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
  T=/nvme/b3/pct2-$c; [ -d $T ] && mv $T /nvme/trash_pc_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/r2c-$c.tgz -C $T; cd $T
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j16 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
  D=/nvme/b3/pcd2-$c; [ -d $D ] && mv $D /nvme/trash_pc_$RANDOM; $PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  P=$((55800 + RANDOM % 100)); printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  make PG_CONFIG=$PFX/bin/pg_config installcheck PGHOST=/tmp PGPORT=$P PGUSER=postgres PROVE_TESTS=ci/noop.pl > /nvme/b3/pc2-$c.log 2>&1; rc=$?
  echo "$c ($(cat GITREV)) rc=$rc $(grep -cE '^ok ' /nvme/b3/pc2-$c.log) ok $(grep -cE '^not ok ' /nvme/b3/pc2-$c.log) not-ok: $(grep -E '^not ok' /nvme/b3/pc2-$c.log | awk '{print $4}' | tr '\n' ' ')"
  $PFX/bin/pg_ctl -D $D -w stop >/dev/null
done
echo PERCOMMIT2_DONE
