#!/bin/bash
# shift.sh: run shift.sql on 1.14.1, on 1.10.0, then upgrade the 1.10.0 cluster in place and re-query
set -u
O=/nvme/fp/shift.out; : > $O
for X in pg18-v1141:5511 pg18-v1100:5512; do
  P=${X#*:}; X=${X%:*}; N=sh-$X
  bash /tmp/pgc.sh $X $N $P init; bash /tmp/pgc.sh $X $N $P start
  /nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X -q -c 'CREATE EXTENSION pg_fts' postgres
  echo "== $X $(/nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -XAtc "select extversion from pg_extension where extname='pg_fts'" postgres)" >> $O
  /nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X -q -f /tmp/shift.sql postgres >> $O 2>&1
done
# in-place upgrade of the 1.10.0 cluster's binaries + extension
X=pg18-v1100; P=5512; N=sh-$X
[ -d /nvme/fp/pg18-upgS ] || cp -a /nvme/fp/pg18-v1100 /nvme/fp/pg18-upgS
bash /tmp/pgc.sh $X $N $P stop
cp /nvme/fp/pg18-v1141/lib/postgresql/pg_fts.so /nvme/fp/pg18-upgS/lib/postgresql/
cp /nvme/fp/pg18-v1141/share/postgresql/extension/pg_fts* /nvme/fp/pg18-upgS/share/postgresql/extension/
/nvme/fp/pg18-upgS/bin/pg_ctl -D /nvme/fp/d-$N -l /nvme/fp/d-$N/log -w start >/dev/null
PS="/nvme/fp/pg18-upgS/bin/psql -h /tmp -p $P -U postgres -X postgres"
$PS -q -c 'ALTER EXTENSION pg_fts UPDATE'
echo "== upgraded in place: $($PS -Atc "select extversion from pg_extension where extname='pg_fts'"); then VACUUM + fts_merge" >> $O
$PS -q -c 'VACUUM sh' -c "SELECT fts_merge('sh_fts')" >/dev/null
$PS -At -c "SET enable_seqscan=off" -c "SET enable_indexscan=off" -c "SELECT 'bitmap_rows '||count(*)||' bitmap_false '||count(*) FILTER (WHERE NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))) FROM sh WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','visibility & map')" >> $O 2>&1
$PS -q -c 'REINDEX INDEX sh_fts'
echo "== after REINDEX" >> $O
$PS -At -c "SET enable_seqscan=off" -c "SET enable_indexscan=off" -c "SELECT 'bitmap_rows '||count(*)||' bitmap_false '||count(*) FILTER (WHERE NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'))) FROM sh WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','visibility & map')" >> $O 2>&1
echo SHIFT_DONE >> $O
