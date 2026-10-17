#!/bin/bash
# vacuum_parallel layout, fix vs mutB, PG18: size after each step; with/without a parallel VACUUM before the serial one
set -uo pipefail
for TAG in ${TAGS:-fix mutB v140}; do
 for PAR in 1 0; do
  B=/nvme/b3/repro/pg-$TAG/bin; D=/nvme/b3/vpd-$TAG-$PAR; PORT=55671
  $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_vp_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
  $P -f /tmp/bug2e_d.sql >/dev/null
  $P -c "CREATE EXTENSION IF NOT EXISTS pg_freespacemap" >/dev/null 2>&1
  fr() { $P -c "select count(*) filter (where avail>=4096)||'/'||count(*) from pg_freespace('m_fts')"; }
  line="[$TAG par=$PAR] after merge $($P -c "select pg_relation_size('m_fts')/8192") free $(fr)"
  if [ $PAR = 1 ]; then for i in 1 2 3; do $P -c "DELETE FROM m WHERE id % 100 = $i" >/dev/null; $P -c "SET min_parallel_index_scan_size=0" -c "SET max_parallel_maintenance_workers=2" -c "VACUUM (PARALLEL 2) m"; line="$line | par#$i $($P -c "select pg_relation_size('m_fts')/8192")"; done; fi
  for i in 1 2 3; do $P -c "DELETE FROM m WHERE id % 100 = $((i+10))" >/dev/null; $P -c "VACUUM (PARALLEL 0) m"; line="$line | serial#$i $($P -c "select pg_relation_size('m_fts')/8192") free $(fr)"; done
  echo "$line"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
 done
done
echo VPDIAG_DONE
