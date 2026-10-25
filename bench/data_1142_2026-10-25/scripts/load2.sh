#!/bin/bash
# load2.sh <prefix> <port> <pass_lo> <pass_hi> <W> <abort_pct> <logdir> <ovs_pct>
# like load.sh; abort = same batch first ROLLBACKed; ovs = chunk inserted with message repeated 30x (oversized ftsdoc path)
PFX=$1; PORT=$2; PLO=$3; PHI=$4; W=$5; AB=$6; LOG=$7; OVS=${8:-0}
NCH=$(ls /nvme/fp/chunks | wc -l)
emit() {
  local c=$1 m=$2 o=$3 lo=$(( $1*1000+1 )) hi=$(( ($1+1)*1000 )) f=$(printf /nvme/fp/chunks/c%04d $1)
  if [ $o = 1 ]; then echo "INSERT INTO ag (n, tree_hash, message) SELECT n, hash, repeat(message || ' ', 30) FROM src WHERE n BETWEEN $lo AND $hi ORDER BY n;"; return; fi
  case $m in
  0) echo "COPY ag (n, tree_hash, message) FROM '$f';" ;;
  1) echo "INSERT INTO ag (n, tree_hash, message) SELECT n, hash, message FROM src WHERE n BETWEEN $lo AND $hi ORDER BY n;" ;;
  2) echo "SELECT format('INSERT INTO ag (n, tree_hash, message) VALUES %s', string_agg(format('(%s,%L,%L)', n, hash, message), ',' ORDER BY n)) FROM src WHERE n BETWEEN $lo AND $hi GROUP BY (n-1)/100 ORDER BY (n-1)/100 \\gexec" ;;
  3) echo "\\copy ag (n, tree_hash, message) FROM '$f'" ;;
  esac
}
for w in $(seq 0 $((W-1))); do
 (
  for p in $(seq $PLO $PHI); do
   for c in $(seq 0 $((NCH-1))); do
     [ $(( (c + p) % W )) -eq $w ] || continue
     m=$(( (c*7 + p*3) % 4 )); o=0
     [ $OVS -gt 0 ] && [ $(( (c*13 + p*5) % 100 )) -lt $OVS ] && o=1
     if [ $AB -gt 0 ] && [ $((RANDOM % 100)) -lt $AB ]; then echo "BEGIN;"; emit $c $m $o; echo "ROLLBACK;"; fi
     echo "BEGIN;"; emit $c $m $o; echo "COMMIT;"
   done
  done
 ) | $PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q postgres > $LOG/load-w$w.log 2>&1 &
done
wait
