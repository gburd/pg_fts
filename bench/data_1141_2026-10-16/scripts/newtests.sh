#!/bin/bash
# Run planner_pending + vacuum_parallel + bm25_vacuum_growth against an install (TAG, MAJOR) using the
# fix tree's sql/ and specs/ (so the same test text runs against fix and mutant .so files).
set -uo pipefail
TAG=${TAG:-fix}; M=${M:-18}; PORT=${PORT:-55631}
if [ $M = 18 ]; then PFX=/nvme/b3/repro/pg-$TAG; PGSRC=/nvme/postgresql-18.6; else PFX=/nvme/b3/pg17-$TAG; PGSRC=/nvme/postgresql-17.10; fi
T=/nvme/b3/nt-$TAG-$M; [ -d $T ] && mv $T /nvme/trash_nt_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/fix.tgz -C $T
D=/nvme/b3/ntdata-$TAG-$M; $PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_nt_$RANDOM
$PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\nlog_min_messages=info\n" >> $D/postgresql.conf
$PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
cd $T
$PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q -c "CREATE DATABASE contrib_regression" -c "CREATE DATABASE isolation_regression"
for db in contrib_regression isolation_regression; do $PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q -d $db -c "CREATE EXTENSION pg_fts"; done
for t in ${TESTS:-planner_pending vacuum_parallel}; do
  [ -f expected/$t.out ] || touch expected/$t.out
  $PGSRC/src/test/regress/pg_regress --bindir=$PFX/bin --host=/tmp --port=$PORT --user=postgres --dbname=contrib_regression --use-existing --inputdir=. $t 2>&1 | grep -E "^(ok|not ok)|^\s*(ok|FAILED)|# " | head -3
  cp results/$t.out /nvme/b3/nt-$TAG-$M-$t.out 2>/dev/null
done
for s in ${SPECS:-bm25_vacuum_growth}; do
  [ -f expected/$s.out ] || touch expected/$s.out
  $PGSRC/src/test/isolation/pg_isolation_regress --bindir=$PFX/bin --host=/tmp --port=$PORT --user=postgres --dbname=isolation_regression --use-existing --inputdir=. --outputdir=output_iso $s 2>&1 | grep -E "^(ok|not ok)|^\s*(ok|FAILED)" | head -3
  cp output_iso/results/$s.out /nvme/b3/nt-$TAG-$M-$s.out 2>/dev/null
done
$PFX/bin/pg_ctl -D $D -m fast -w stop >/dev/null
echo NEWTESTS_DONE
