#!/bin/bash
# upgarm.sh <name> <port>: 1.10.0 build+load WITHOUT aborts (1 session), upgrade in place to 1.14.1,
# then 1.14.1 loads WITH 10% aborts + vacuum + reuse.  Any FP must come from 1.14.1.
N=$1; PORT=$2; X=pg18-$N
[ -d /nvme/fp/$X ] || cp -a /nvme/fp/pg18-v1100 /nvme/fp/$X
PFX=/nvme/fp/$X; OUT=/nvme/fp/out-$N; mkdir -p $OUT; R=$OUT/result.txt
PSQL="$PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q postgres"
bash /tmp/pgc.sh $X $N $PORT init || exit 1
sed -i 's/^shared_buffers = 4GB/shared_buffers = 2GB/' /nvme/fp/d-$N/postgresql.conf
bash /tmp/pgc.sh $X $N $PORT start || exit 1
$PSQL -f /tmp/setup.sql
$PSQL -c "INSERT INTO ag (n, tree_hash, message) SELECT n, hash, message FROM src WHERE n <= 20000"
$PSQL -c "CREATE INDEX idx_ag_msg_fts ON ag USING fts (to_ftsdoc('english', message))"
echo "built $(date -u +%T) ext $($PSQL -At -c "select extversion from pg_extension where extname='pg_fts'")" >> $R
bash /tmp/load2.sh $PFX $PORT 1 5 1 0 $OUT 0
$PSQL -c "VACUUM ag"
bash /tmp/diff.sh $PFX $PORT "$N on-1.10.0" $R
bash /tmp/pgc.sh $X $N $PORT stop
cp /nvme/fp/pg18-v1141/lib/postgresql/pg_fts.so $PFX/lib/postgresql/
cp /nvme/fp/pg18-v1141/share/postgresql/extension/pg_fts* $PFX/share/postgresql/extension/
bash /tmp/pgc.sh $X $N $PORT start
$PSQL -c "ALTER EXTENSION pg_fts UPDATE"
echo "upgraded $($PSQL -At -c "select extversion from pg_extension where extname='pg_fts'")" >> $R
for cy in 1 2; do
  touch $OUT/loading; ( while [ -f $OUT/loading ]; do sleep 20; $PSQL -c "VACUUM ag" >> $OUT/vac.log 2>&1; done ) & VP=$!
  bash /tmp/load2.sh $PFX $PORT 1 6 6 10 $OUT 2
  rm -f $OUT/loading; wait $VP
  $PSQL -c "VACUUM ag" -c "VACUUM ag"
  $PSQL -c "INSERT INTO ag (n, tree_hash, message) SELECT -g, 'x', 'zzfiller qqfiller ' || g FROM generate_series(1, 200000) g"
  bash /tmp/diff.sh $PFX $PORT "$N 1.14.1 cycle $cy" $R
done
echo ARM_DONE >> $R
