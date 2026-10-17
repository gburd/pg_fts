#!/bin/bash
# Bug 2 variants: what makes the reporter's steps fire?  PG18.6, wal_level=replica.
set -uo pipefail
R=/nvme/b3/repro; PORT=55622
arm() {  # $1 build tag, $2 run tag, $3 pre-step on build version (none|vacuum|autovac), $4 extra
  local BT=$1 RT=$2 PRE=$3 AV=off D=/nvme/b3/bug2b-$1-$2-$3
  [ $PRE = autovac ] && AV=on
  $R/pg-$BT/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_b2_$RANDOM
  $R/pg-$BT/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=$AV\nautovacuum_naptime=5s\nlog_min_messages=info\n" >> $D/postgresql.conf
  $R/pg-$BT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  local P="$R/pg-$BT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"
  $P -f /tmp/bug2_load.sql >/dev/null
  [ $PRE = vacuum ] && $P -c "VACUUM m"
  [ $PRE = autovac ] && { for i in $(seq 1 60); do n=$($P -c "select autovacuum_count from pg_stat_user_tables where relname='m'"); [ "$n" -ge 1 ] && break; sleep 2; done; echo "   autovacuum_count=$n after ${i}x2s"; }
  local fsm="select count(*) filter (where avail >= 4096) from pg_freespace('m_fts')"
  $P -c "CREATE EXTENSION IF NOT EXISTS pg_freespacemap" 2>/dev/null
  echo "== build $BT pre=$PRE -> run $RT: fts $($P -c "select pg_relation_size('m_fts')/8192") blocks, free(fsm) $($P -c "$fsm" 2>&1)"
  if [ $BT != $RT ]; then
    $R/pg-$BT/bin/pg_ctl -D $D -m fast -w stop >/dev/null
    $R/pg-$RT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
    P="$R/pg-$RT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"
    $P -c "ALTER EXTENSION pg_fts UPDATE"
  fi
  $P -c "DELETE FROM m WHERE id % 50 = 0"
  echo "   [$($P -c "select extversion from pg_extension where extname='pg_fts'")] VACUUM m: $($P -c 'VACUUM m' 2>&1 | tr '\n' ' ' | head -c 200)  -> fts $($P -c "select pg_relation_size('m_fts')/8192") blocks"
  $R/pg-$RT/bin/pg_ctl -D $D -m fast -w stop >/dev/null
}
for x in v100 v130 v140 fix; do [ -f $R/pg-$x/lib/postgresql/pg_freespacemap.so ] || (cd /nvme/postgresql-18.6/contrib/pg_freespacemap && make -s install prefix=$R/pg-$x >/dev/null 2>&1; make -s -C /nvme/postgresql-18.6/contrib/pg_freespacemap install DESTDIR= bindir=$R/pg-$x/bin pkglibdir=$R/pg-$x/lib/postgresql datadir=$R/pg-$x/share/postgresql >/dev/null 2>&1); done
for x in v100 v130 v140 fix; do ls $R/pg-$x/lib/postgresql/pg_freespacemap.so >/dev/null 2>&1 || echo "no fsm ext in $x"; done
arm v100 v130 vacuum
arm v100 v130 autovac
arm v130 v130 vacuum
arm v130 v130 autovac
arm v100 v140 autovac
arm v140 v140 autovac
arm v100 fix autovac
echo BUG2B_DONE
