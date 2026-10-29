#!/bin/bash
# duprate150.sh: duplicate-row rate of ranked scans racing inline flushes (no debugger), 1.14.3 (PGXN zip) vs 1.15.0
# (release tree), PG17 + PG18, 5 runs each: 8 inserters x 3000 single-row commits (flush threshold 20), 8 readers x 300
# x (top-10 'fresh', top-1000 'fresh & apple').  1.14.3 measured 25 of 24,000 top-1000 queries with a repeated row
# (CHANGELOG 1.14.3 Known issues).  Also counts segfaults in the server log.
O=/nvme/dr150; mkdir -p $O; exec > $O/duprate.log 2>&1
cd $O; [ -f pg_fts-1.14.3.zip ] || curl -sfLO https://api.pgxn.org/dist/pg_fts/1.14.3/pg_fts-1.14.3.zip
echo "zip sha256 $(sha256sum pg_fts-1.14.3.zip | cut -c1-16) (expect f429f8698e693b78)"
for M in 17 18; do for L in v1143 r150; do
  PFX=$O/pfx$M-$L; [ -d $PFX ] || cp -a /nvme/pg$M $PFX; B=$PFX/bin
  S=$O/src$M-$L; [ -d $S ] && mv $S /nvme/trash_dr_$RANDOM; mkdir -p $S
  if [ $L = v1143 ]; then (cd $S && unzip -q $O/pg_fts-1.14.3.zip); S=$S/pg_fts-1.14.3; else tar xzf /nvme/g150/final.tgz -C $S; fi
  (cd $S && make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo "BUILD FAIL $M $L"; continue; }
  D=$O/d$M-$L; PORT=59$M; [ $L = r150 ] && PORT=58$M
  [ -d $D ] && mv $D /nvme/trash_dr_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nfsync=off\nautovacuum=off\nmax_connections=40\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  echo "== PG$M $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) $(grep default_version $S/pg_fts.control)"
  for r in 1 2 3 4 5; do
    Q="$B/psql -X -q -h /tmp -p $PORT -U postgres -d dr"
    $B/dropdb -h /tmp -p $PORT -U postgres --if-exists dr >/dev/null 2>&1; $B/createdb -h /tmp -p $PORT -U postgres dr
    $Q -c "CREATE EXTENSION pg_fts"; $Q -f /tmp/g/ds_setup.sql 2>/dev/null
    for i in $(seq 8); do $Q -v n=3000 -f /tmp/g/ds_ins.sql > $O/ins_${M}_${L}_${r}_$i.out 2>&1 & done
    for i in $(seq 8); do $Q -v n=300 -f /tmp/g/ds_rd.sql > $O/rd_${M}_${L}_${r}_$i.out 2>&1 & done
    wait
    echo "PG$M $L run $r: readers_done=$(cat $O/rd_${M}_${L}_${r}_*.out | grep -c READER) dup_top10=$(cat $O/rd_${M}_${L}_${r}_*.out | grep -oE 'dup_top10=[0-9]+' | cut -d= -f2 | paste -sd+ | bc) dup_top1000=$(cat $O/rd_${M}_${L}_${r}_*.out | grep -oE 'dup_top1000=[0-9]+' | cut -d= -f2 | paste -sd+ | bc) errors=$(cat $O/rd_${M}_${L}_${r}_*.out $O/ins_${M}_${L}_${r}_*.out | grep -c ERROR) rows=$($Q -At -c 'SELECT count(*) FROM ds') segments=$($Q -At -c "SELECT fts_index_nsegments('ds_fts')")"
  done
  echo "PG$M $L segfaults: $(grep -c 'terminated by signal' $D/log)"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done; done
echo DUPRATE150_DONE
