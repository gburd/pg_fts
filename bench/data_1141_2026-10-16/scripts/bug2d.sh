#!/bin/bash
# Bug 2 follow-up: index size across repeated parallel VACUUMs after the 1.14.0 parallel-mode
# truncation guard.  Scenario A: reporter's (1.10.0 parallel build -> upgrade).  Scenario B: native
# (build on RUN tag, delete high id range, fts_merge -> free tail) like sql/vacuum_parallel.
set -uo pipefail
R=/nvme/b3/repro; PORT=55624
sz() { $P -c "select pg_relation_size('m_fts')/8192"; }
run() {  # $1 scenario $2 build tag $3 run tag
  local SC=$1 BT=$2 RT=$3 D=/nvme/b3/bug2d-$1-$2-$3
  $R/pg-$BT/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_b2_$RANDOM
  $R/pg-$BT/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
  $R/pg-$BT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$R/pg-$BT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"
  if [ $SC = A ]; then sed "s/^CREATE INDEX m_fts/ALTER TABLE m SET (parallel_workers = 4); CREATE INDEX m_fts/" /tmp/bug2_load.sql > /tmp/bug2d_load.sql
  else sed "s/generate_series(1, 20000) g/generate_series(1, 60000) g/" /tmp/bug2_load.sql > /tmp/bug2d_load.sql; fi
  $P -f /tmp/bug2d_load.sql >/dev/null
  if [ $BT != $RT ]; then
    $R/pg-$BT/bin/pg_ctl -D $D -m fast -w stop >/dev/null; $R/pg-$RT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
    P="$R/pg-$RT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"; $P -c "ALTER EXTENSION pg_fts UPDATE"
  fi
  [ $SC = B ] && $P -c "DELETE FROM m WHERE id > 12000" -c "SELECT fts_merge('m_fts')" >/dev/null
  local line="[$SC $BT->$RT $($P -c "select extversion from pg_extension where extname='pg_fts'")] start $(sz)"
  for i in 1 2 3 4; do
    $P -c "DELETE FROM m WHERE id % 97 = $i" >/dev/null
    e=$($P -c 'VACUUM m' 2>&1 | grep -c ERROR); line="$line | par#$i $(sz)$([ $e -gt 0 ] && echo '(ERR)')"
  done
  $P -c "DELETE FROM m WHERE id % 97 = 9" >/dev/null
  $P -c 'VACUUM (PARALLEL 0) m' >/dev/null 2>&1; line="$line | serial $(sz)"
  $P -c "DELETE FROM m WHERE id % 97 = 10" >/dev/null
  $P -c 'VACUUM m' >/dev/null 2>&1; line="$line | par#5 $(sz)"
  echo "$line | idx=$($P -c "set enable_seqscan=off; select count(*) from m where to_ftsdoc('english',body) @@@ 'w30'::ftsquery") heap=$($P -c "select count(*) from m where fts_match(to_ftsdoc('english',body),'w30'::ftsquery)")"
  $R/pg-$RT/bin/pg_ctl -D $D -m fast -w stop >/dev/null
}
run A v100 v130; run A v100 v140; run A v100 fix2
run B v140 v140; run B fix2 fix2
echo BUG2D_DONE
