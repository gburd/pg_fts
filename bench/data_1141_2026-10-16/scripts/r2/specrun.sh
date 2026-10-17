#!/bin/bash
# specrun.sh <prefix> <major> <port> <specdir> <spec...>: run isolation specs from <specdir> against an install
set -uo pipefail
PFX=$1; M=$2; PORT=$3; SD=$4; shift 4
PGSRC=$(ls -d /nvme/postgresql-$M.*)
D=/nvme/b3/specdata-$PORT; $PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_sp_$RANDOM
$PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\n" >> $D/postgresql.conf
$PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
cd $SD; mkdir -p expected
echo "== $($PFX/bin/postgres --version) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
for s in "$@"; do
  [ -f expected/$s.out ] || touch expected/$s.out
  $PGSRC/src/test/isolation/pg_isolation_regress --bindir=$PFX/bin --host=/tmp --port=$PORT --user=postgres --inputdir=. --outputdir=out_$PORT $s 2>&1 | grep -E "ok|FAIL" | head -3
done
$PFX/bin/pg_ctl -D $D -m fast -w stop >/dev/null
echo SPECRUN_DONE
