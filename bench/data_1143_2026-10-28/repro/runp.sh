for M in 17 18; do for L in v1142 fix; do
  P=/nvme/iss/pg$M-$L/bin; PO=57; [ $L = fix ] && PO=58
  $P/dropdb -h /tmp -p $PO$M -U postgres --if-exists r >/dev/null 2>&1; $P/createdb -h /tmp -p $PO$M -U postgres r
  echo "##### PG$M $L $1"; $P/psql -X -At -h /tmp -p $PO$M -U postgres -d r -f $1 2>&1
done; done
