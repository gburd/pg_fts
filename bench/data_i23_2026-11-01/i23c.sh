#!/bin/bash
# i23c.sh: the I19b readings shape at a second scale: the i23b 640k x 60-token index (PG18), v1151 vs head (+head2 A/A).
set -u
M=18; O=/nvme/i23b-$M; exec > $O/i23c.log 2>&1; cd $O
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir); D=$O/data; P=59$M
PS="numactl --physcpubind=16-17 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so
        numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; echo "  [so=$1 $(md5sum $LIB/pg_fts.so | cut -c1-8)]"; }
QRD="(zzzq | zzzx) & (t10 | t2:*)"; QT1="zzzq & (t10 | t2:*)"; QPR="(zzzq | build) & (t10 | t2:*)"
rq() { echo "SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ '$1'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> '$1'::ftsquery LIMIT 10;"; }
ids() { $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT coalesce(string_agg(id::text, ','), '<none>') FROM ($(rq "$1" | sed 's/;$//')) s" | tail -1; }
for L in v1151 head; do use $L
  for q in "$QRD" "$QT1" "$QPR"; do r=$(ids "$q"); echo "  CORR $L [$q] top10=$(echo $r | md5sum | cut -c1-8) n=$(echo $r | tr ',' '\n' | grep -c .) ids=${r:0:60}"; done
done
echo "  heap RD=$($PS -At -c "SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc('simple', body), '$QRD'::ftsquery)") PR=$($PS -At -c "SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc('simple', body), '$QPR'::ftsquery)")"
t() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; rq "$1"; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
bufs() { $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) $(rq "$1")" | grep -m1 -oE 'shared hit=[0-9]+( read=[0-9]+)?'; }
for r in 1 2 3 4; do
  if [ $((r % 2)) = 1 ]; then ORD="v1151 head head2 head2 head v1151"; else ORD="head2 head v1151 v1151 head head2"; fi
  for L in $ORD; do use $L >/dev/null; sleep 5; echo "T round=$r so=$L RD=$(t "$QRD") T1=$(t "$QT1") PR=$(t "$QPR")"; done
done
for L in v1151 head; do use $L >/dev/null; echo "BUFS $L RD=$(bufs "$QRD") T1=$(bufs "$QT1") PR=$(bufs "$QPR")"; done
$B/pg_ctl -D $D -w stop >/dev/null
echo I23C_DONE
