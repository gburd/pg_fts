#!/bin/bash
O=/nvme/fp/mech.out; : > $O
for X in pg18-v1100:5512 pg18-v1141:5511 pg17-v1141:5513; do
  P=${X#*:}; X=${X%:*}; N=mech-$X
  bash /tmp/pgc.sh $X $N $P init >/dev/null; sed -i 's/^shared_buffers = 4GB/shared_buffers = 512MB/' /nvme/fp/d-$N/postgresql.conf
  bash /tmp/pgc.sh $X $N $P start >/dev/null
  PS="/nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X postgres"
  $PS -q -c 'CREATE EXTENSION pg_fts'
  echo "== $X $($PS -Atc "select extversion from pg_extension where extname='pg_fts'") $($PS -Atc 'show server_version')" >> $O
  for m in abort conflict delete uniqfail copyfail; do $PS -q -At -v mode=$m -f /tmp/mech.sql 2>&1 | grep -v '^$' >> $O; done
  bash /tmp/pgc.sh $X $N $P stop >/dev/null
done
echo MECH_DONE >> $O
