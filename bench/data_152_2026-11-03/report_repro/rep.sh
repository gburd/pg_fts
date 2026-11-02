#!/bin/bash
# rep.sh <label> <tree.tgz>: the reporter's repro.sql, unchanged, at full size (1.88M rows, 23,313 moves), on PG 18.6,
# plus count(*) of 'vacuum' through the bitmap path at each probe (added as a separate session per step is not
# possible without editing the script, so a second pass below times count(*) after the run's final state).
set -u
L=$1; T=$2; O=/nvme/rep; mkdir -p $O; cd $O
B=/nvme/pg18/bin; PFX=$O/pfx-$L; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
S=$O/src-$L; [ -d $S ] || { mkdir -p $S; tar xzf $T -C $S; }
(cd $S && make -s -j16 PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1) || { echo BUILD FAIL; exit 1; }
D=$O/d-$L; P=7318; [ -d $D ] && mv $D $O/trash_$RANDOM
$PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=16GB\nmaintenance_work_mem=8GB\nmax_wal_size=32GB\njit=off\nautovacuum=off\n" >> $D/postgresql.conf
numactl --physcpubind=8-15 --membind=0 $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null || { echo START FAIL; exit 1; }
echo "== $L GITREV=$(cat $S/GITREV) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8) $(date -u +%H:%M)"
numactl --physcpubind=16-17 --membind=0 $PFX/bin/psql -X -h /tmp -p $P -U postgres -d postgres -At -v nrows=1880000 -v nmoves=23313 -f /tmp/repro.sql 2>&1 | grep -v "^$"
# final state is step I (moves, VACUUM, no pack): unranked count(*) of 'vacuum' through the bitmap path, and a
# 4-term OR top-200 through the executor, warm, median of 5
for q in "count" "or4"; do
  ms=$( { echo "SET enable_seqscan=off;"; [ $q = count ] && echo "SET enable_indexscan=off;"; echo "\\timing on"; for i in 1 2 3 4 5 6; do echo "\\o /dev/null";
    if [ $q = count ]; then echo "SELECT count(*) FROM own WHERE to_ftsdoc('english'::regconfig, ((head || ' '::text) || own)) @@@ 'vacuum'::ftsquery;";
    else echo "SELECT num FROM own WHERE to_ftsdoc('english'::regconfig, ((head || ' '::text) || own)) @@@ 'remov | vacuum | w1 | w2'::ftsquery ORDER BY to_ftsdoc('english'::regconfig, ((head || ' '::text) || own)) <=> 'remov | vacuum | w1 | w2'::ftsquery LIMIT 200;"; fi; echo "\\o"; done; } \
    | numactl --physcpubind=16-17 $PFX/bin/psql -X -q -h /tmp -p $P -U postgres -d postgres 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -5 | sort -n | sed -n 3p)
  echo "  step I extra: $q median-of-5 = $ms ms"
done
$PFX/bin/pg_ctl -D $D -w stop >/dev/null
echo "REP_DONE $L $(date -u +%H:%M)"
