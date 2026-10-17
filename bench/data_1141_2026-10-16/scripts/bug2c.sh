#!/bin/bash
# Bug 2: does the reporter's sequence fire when the 1.10.0 build is PARALLEL (bloated index)?
set -uo pipefail
R=/nvme/b3/repro; PORT=55623
arm() {  # $1 build tag, $2 run tag, $3 build parallel workers (0 = serial)
  local BT=$1 RT=$2 PW=$3 D=/nvme/b3/bug2c-$1-$2-$3
  $R/pg-$BT/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_b2_$RANDOM
  $R/pg-$BT/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\nlog_min_messages=info\n" >> $D/postgresql.conf
  $R/pg-$BT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  local P="$R/pg-$BT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"
  sed "s/^CREATE INDEX m_fts/ALTER TABLE m SET (parallel_workers = $PW); CREATE INDEX m_fts/" /tmp/bug2_load.sql > /tmp/bug2c_load.sql
  $P -f /tmp/bug2c_load.sql >/dev/null
  $P -c "CREATE EXTENSION IF NOT EXISTS pg_freespacemap" >/dev/null 2>&1
  echo "== build $BT parallel_workers=$PW -> run $RT: heap $($P -c "select pg_relation_size('m')/8192") blocks, fts $($P -c "select pg_relation_size('m_fts')/8192") blocks, nseg $($P -c "select fts_index_nsegments('m_fts')"), fsm-free $($P -c "select count(*) filter (where avail >= 4096) from pg_freespace('m_fts')")"
  if [ $BT != $RT ]; then
    $R/pg-$BT/bin/pg_ctl -D $D -m fast -w stop >/dev/null
    $R/pg-$RT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
    P="$R/pg-$RT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"
    $P -c "ALTER EXTENSION pg_fts UPDATE"
  fi
  $P -c "DELETE FROM m WHERE id % 50 = 0"
  echo "   [$($P -c "select extversion from pg_extension where extname='pg_fts'")] VACUUM (VERBOSE) m: $($P -c 'VACUUM (VERBOSE) m' 2>&1 | grep -E 'ERROR|parallel vacuum worker|CONTEXT' | tr '\n' ' ' | head -c 300)"
  echo "   after: fts $($P -c "select pg_relation_size('m_fts')/8192") blocks; idx count $($P -c "set enable_seqscan=off; select count(*) from m where to_ftsdoc('english',body) @@@ 'w30'::ftsquery") heap $($P -c "select count(*) from m where fts_match(to_ftsdoc('english',body),'w30'::ftsquery)")"
  $R/pg-$RT/bin/pg_ctl -D $D -m fast -w stop >/dev/null
}
arm v100 v130 0
arm v100 v130 4
arm v100 v140 4
arm v100 fix 4
arm v130 v130 4
arm v140 v140 4
echo BUG2C_DONE
