#!/bin/bash
# dstress.sh <M> <arm fix|v1142> <inserters> <readers> <rows per inserter> <queries per reader>: no debugger; does a
# ranked scan crash or return a repeated row while inline flushes run?  Cores on (bt saved).
M=$1; L=$2; NI=$3; NR=$4; RI=$5; QR=$6; P=/nvme/iss/pg$M-$L/bin; D=/nvme/iss/d$M-$L; PO=57; [ $L = fix ] && PO=58; PORT=$PO$M; O=/nvme/iss/ds$M-$L; mkdir -p $O
for c in $D/core*; do [ -f $c ] && mv $c /nvme/trash_core_$RANDOM; done
ulimit -c unlimited
bash /tmp/clstop.sh $P $D
$P/pg_ctl -D $D -l $D/log -w start >/dev/null 2>&1 || { echo START_FAILED; exit 1; }
LOG0=$(wc -l < $D/log)
$P/dropdb -h /tmp -p $PORT -U postgres --if-exists dsx >/dev/null 2>&1; $P/createdb -h /tmp -p $PORT -U postgres dsx
Q="$P/psql -X -q -h /tmp -p $PORT -U postgres -d dsx"
$Q -c "CREATE EXTENSION pg_fts"; $Q -f /tmp/ds_setup.sql
t0=$(date +%s)
for i in $(seq $NI); do $Q -v n=$RI -f /tmp/ds_ins.sql > $O/ins$i.out 2>&1 & done
for r in $(seq $NR); do $Q -v n=$QR -f /tmp/ds_rd.sql > $O/rd$r.out 2>&1 & done
wait
sleep 3; $P/pg_ctl -D $D -w -t 60 status >/dev/null 2>&1; for i in $(seq 30); do $P/pg_isready -h /tmp -p $PORT -q && break; sleep 1; done
echo "PG$M $L so=$(md5sum $P/../lib/postgresql/pg_fts.so | cut -c1-8) inserters=$NI x $RI rows readers=$NR x $QR secs=$(( $(date +%s) - t0 )) rows=$($Q -At -c 'SELECT count(*) FROM ds') segments=$($Q -At -c "SELECT fts_index_nsegments('ds_fts')")"
cat $O/rd*.out | grep -E "READER|ERROR" | sort | uniq -c
grep -h ERROR $O/ins*.out | sort | uniq -c | head -3
echo "segfaults in log: $(tail -n +$LOG0 $D/log | grep -c "terminated by signal")"
bash /tmp/clstop.sh $P $D
for c in $D/core*; do [ -f $c ] && { echo "core $c"; gdb -batch -ex "bt 25" $P/postgres $c 2>&1 | grep -E "^#" | cut -c1-200 > $O/bt.txt; cat $O/bt.txt; }; done
