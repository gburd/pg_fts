#!/bin/bash
# r2tests.sh <tgz> <prefix> <major> <port> <outtag> : run the listed regress + isolation tests from the tgz's sql/ specs/
set -uo pipefail
TGZ=$1; PFX=$2; M=$3; PORT=$4; OT=$5
PGSRC=$(ls -d /nvme/postgresql-$M.*/ | head -1); PGSRC=${PGSRC%/}
T=/nvme/b3/r2t-$OT; [ -d $T ] && mv $T /nvme/trash_r2t_$RANDOM; mkdir -p $T; tar xzf $TGZ -C $T; cd $T
D=/nvme/b3/r2tdata-$OT; $PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_r2t_$RANDOM
$PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\n" >> $D/postgresql.conf
$PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
echo "== $OT: $($PFX/bin/postgres --version) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
for t in ${TESTS:-planner_pending planner_indexes}; do
  $PGSRC/src/test/regress/pg_regress --bindir=$PFX/bin --host=/tmp --port=$PORT --user=postgres --inputdir=. --outputdir=out_r --dbname=contrib_regression --load-extension=pg_fts $t > out_r_$t.log 2>&1; grep -E "^(ok|not ok)|Bail" out_r_$t.log | sed "s/^/regress /"
  cp out_r/results/$t.out /nvme/b3/r2-$OT-$t.out 2>/dev/null
done
for s in ${SPECS:-bm25_cic_planner bm25_vacuum_growth}; do
  $PGSRC/src/test/isolation/pg_isolation_regress --bindir=$PFX/bin --host=/tmp --port=$PORT --user=postgres --inputdir=. --outputdir=out_i --dbname=isolation_regression --load-extension=pg_fts $s > out_i_$s.log 2>&1; grep -E "^(ok|not ok)|Bail" out_i_$s.log | sed "s/^/iso /"
  cp out_i/results/$s.out /nvme/b3/r2-$OT-$s.out 2>/dev/null
done
$PFX/bin/pg_ctl -D $D -m fast -w stop >/dev/null
echo R2TESTS_DONE
