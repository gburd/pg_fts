#!/bin/bash
# duprate.sh: duplicate-row rate of ranked scans racing inline flushes, WITHOUT a debugger, on the crash-fixed build
# (gate prefix pfx<M> with the 7f233ca .so).  5 runs x PG17/PG18; 8 inserters x 3000 rows (threshold 20), 8 readers x 300.
G=/nvme/iss/gate; O=/nvme/iss/duprate; mkdir -p $O; exec > $O/duprate.log 2>&1
for M in 17 18; do
  B=$G/pfx$M/bin; D=$O/d$M; PORT=599$M
  [ -d $D ] && mv $D /nvme/trash_dr_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nfsync=off\nautovacuum=off\nmax_connections=40\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  echo "== PG$M so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
  for r in 1 2 3 4 5; do
    Q="$B/psql -X -q -h /tmp -p $PORT -U postgres -d dr"
    $B/dropdb -h /tmp -p $PORT -U postgres --if-exists dr >/dev/null 2>&1; $B/createdb -h /tmp -p $PORT -U postgres dr
    $Q -c "CREATE EXTENSION pg_fts"; $Q -f /tmp/ds_setup.sql 2>/dev/null
    for i in $(seq 8); do $Q -v n=3000 -f /tmp/ds_ins.sql > $O/ins_${M}_${r}_$i.out 2>&1 & done
    for i in $(seq 8); do $Q -v n=300 -f /tmp/ds_rd.sql > $O/rd_${M}_${r}_$i.out 2>&1 & done
    wait
    echo "PG$M run $r: readers_done=$(cat $O/rd_${M}_${r}_*.out | grep -c READER) dup_top10_queries=$(cat $O/rd_${M}_${r}_*.out | grep -oE 'dup_top10=[0-9]+' | cut -d= -f2 | paste -sd+ | bc) dup_top1000_queries=$(cat $O/rd_${M}_${r}_*.out | grep -oE 'dup_top1000=[0-9]+' | cut -d= -f2 | paste -sd+ | bc) errors=$(cat $O/rd_${M}_${r}_*.out $O/ins_${M}_${r}_*.out | grep -c ERROR) rows=$($Q -At -c 'SELECT count(*) FROM ds')"
  done
  echo "segfaults: $(grep -c 'terminated by signal' $D/log)"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done
echo DUPRATE_DONE
