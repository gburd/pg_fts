#!/bin/bash
# run claims.sql in a fresh database on the 1.14.2 and fix clusters, both majors (ports 57<M>/58<M>)
for M in 17 18; do for L in v1142 fix; do
  P=/nvme/iss/pg$M-$L; D=/nvme/iss/d$M-$L; PO=57; [ $L = fix ] && PO=58
  $P/bin/pg_ctl -D $D -l $D/log -w start >/dev/null 2>&1
  $P/bin/dropdb -h /tmp -p $PO$M -U postgres --if-exists claims >/dev/null 2>&1; $P/bin/createdb -h /tmp -p $PO$M -U postgres claims
  $P/bin/psql -X -q -h /tmp -p $PO$M -U postgres -d claims -c "CREATE EXTENSION pg_fts"
  echo "### PG$M $L so=$(md5sum $P/lib/postgresql/pg_fts.so | cut -c1-8)"
  $P/bin/psql -X -q -h /tmp -p $PO$M -U postgres -d claims -f /tmp/claims.sql 2>&1
  $P/bin/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1
done; done
echo CLAIMS_DONE
