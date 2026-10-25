#!/bin/bash
# load.sh <prefix> <port> <pass_lo> <pass_hi> <W> <abort_pct> <logdir>
PFX=$1; PORT=$2; PLO=$3; PHI=$4; W=$5; AB=$6; LOG=$7
NCH=$(ls /nvme/fp/chunks | wc -l)
emit() { # chunk c, method m
  local c=$1 m=$2 lo=$(( $1*1000+1 )) hi=$(( ($1+1)*1000 )) f=$(printf /nvme/fp/chunks/c%04d $1)
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
     m=$(( (c*7 + p*3) % 4 ))
     if [ $AB -gt 0 ] && [ $((RANDOM % 100)) -lt $AB ]; then
       echo "BEGIN;"; emit $c $m; echo "ROLLBACK;"
     fi
     echo "BEGIN;"; emit $c $m; echo "COMMIT;"
   done
  done
 ) | $PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q postgres > $LOG/load-w$w.log 2>&1 &
done
wait
