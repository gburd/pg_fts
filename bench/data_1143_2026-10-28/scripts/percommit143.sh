#!/bin/bash
# per-commit: build each commit's tree on PG 18.6 into its own prefix, run REGRESS+ISOLATION installcheck
set -uo pipefail
G=/nvme/iss/gate; mkdir -p $G
exec > $G/percommit143.log 2>&1
for c in ${COMMITS}; do
  PFX=$G/pc-$c; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
  T=$G/pct-$c; [ -d $T ] && mv $T /nvme/trash_pc_$RANDOM; mkdir -p $T; tar xzf $G/c-$c.tgz -C $T; cd $T
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j16 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
  D=$G/pcd-$c; [ -d $D ] && mv $D /nvme/trash_pc_$RANDOM; $PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  P=$((55800 + RANDOM % 100)); printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  make PG_CONFIG=$PFX/bin/pg_config installcheck PGHOST=/tmp PGPORT=$P PGUSER=postgres PROVE_TESTS=ci/noop.pl > $G/pc-$c.log 2>&1; rc=$?
  echo "$c ($(cat GITREV)) rc=$rc $(grep -cE '^ok ' $G/pc-$c.log) ok $(grep -cE '^not ok ' $G/pc-$c.log) not-ok: $(grep -E '^not ok' $G/pc-$c.log | awk '{print $4}' | tr '\n' ' ')"
  $PFX/bin/pg_ctl -D $D -w stop >/dev/null
  [ $rc = 0 ] || bad=1
done
[ -z "${bad:-}" ] || { echo PERCOMMIT_NOT_GREEN; exit 1; }
echo PERCOMMIT_DONE
