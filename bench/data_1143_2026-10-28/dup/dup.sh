#!/bin/bash
# dup.sh <M> <arm>: stop a flushing backend (fts_merge) under gdb right after bm25_add_segment_with_room returns,
# run dup_probe.sql from a second session, then let the flush finish and probe again.
M=$1; L=$2; P=/nvme/iss/pg$M-$L; D=/nvme/iss/d$M-$L; PO=57; [ $L = fix ] && PO=58; PORT=$PO$M
SRC=/nvme/iss/src_fix_$M; [ $L = v1142 ] && SRC=/nvme/iss/src142_$M
LINE=$(grep -n "^	bm25_add_segment_with_room(index, &seg);$" $SRC/pg_fts_am.c | tail -1 | cut -d: -f1); NEXT=$((LINE+8))
$P/bin/pg_ctl -D $D -l $D/log -w start >/dev/null 2>&1
Q="$P/bin/psql -X -h /tmp -p $PORT -U postgres"
$P/bin/dropdb -h /tmp -p $PORT -U postgres --if-exists dupx >/dev/null 2>&1; $P/bin/createdb -h /tmp -p $PORT -U postgres dupx
$Q -q -d dupx -c "CREATE EXTENSION pg_fts"
$Q -q -d dupx -f /tmp/dup_setup.sql
echo "== PG$M $L so=$(md5sum $P/lib/postgresql/pg_fts.so | cut -c1-8) break after line $LINE (stop at $NEXT: $(sed -n ${NEXT}p $SRC/pg_fts_am.c | tr -s '\t' ' '))"
# flusher session: get its pid, then run fts_merge (which flushes pending first)
mkfifo /nvme/iss/fl.fifo 2>/dev/null
( $Q -d dupx < /nvme/iss/fl.fifo > /nvme/iss/flusher.out 2>&1 ) &
exec 7> /nvme/iss/fl.fifo
echo "SET application_name = 'dupflusher';" >&7
sleep 2; FP=$($Q -At -d dupx -c "SELECT pid FROM pg_stat_activity WHERE application_name = 'dupflusher'"); echo "flusher pid $FP"
[ -n "$FP" ] || { echo NO_FLUSHER_PID; exit 1; }
gdb -p $FP -batch -ex "set breakpoint pending on" -ex "break pg_fts_am.c:$NEXT" -ex "continue" -ex "bt 3" -ex "shell bash -c '$Q -d dupx -f /tmp/dup_probe.sql > /nvme/iss/probe_mid_${M}_$L.out 2>&1'" -ex "detach" > /nvme/iss/gdb_${M}_$L.out 2>&1 &
GP=$!; sleep 3
echo "SELECT fts_merge('dp_fts') IS NOT NULL AS merged;" >&7
wait $GP
exec 7>&-; sleep 2
$Q -d dupx -f /tmp/dup_probe.sql > /nvme/iss/probe_after_${M}_$L.out 2>&1
grep -E "^#|Breakpoint|bm25_" /nvme/iss/gdb_${M}_$L.out | head -6
grep -qE "^#[01] .*bm25_flush_pending" /nvme/iss/gdb_${M}_$L.out && echo "GDB_STOPPED_IN_FLUSH: yes" || echo "GDB_STOPPED_IN_FLUSH: NO (mid probe invalid)"
echo "flusher: $(tr '\n' ' ' < /nvme/iss/flusher.out)"
echo "-- mid-flush:"; grep -vE "^SET|^$" /nvme/iss/probe_mid_${M}_$L.out
echo "-- after flush:"; grep -vE "^SET|^$" /nvme/iss/probe_after_${M}_$L.out | head -30
$P/bin/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1; mv /nvme/iss/fl.fifo /nvme/trash_fifo_$RANDOM
