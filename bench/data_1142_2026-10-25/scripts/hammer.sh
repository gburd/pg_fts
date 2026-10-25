#!/bin/bash
# hammer.sh <name> <prefix-name> <port> <W> <abort_pct> <npasses> <vac_every_s> <ovs_pct> <flush_thr> "<reloptions or empty>" <cycles>
N=$1; X=$2; PORT=$3; W=$4; AB=$5; NP=$6; VE=$7; OVS=$8; FT=$9; RO=${10}; CY=${11}
PFX=/nvme/fp/$X; OUT=/nvme/fp/out-$N; mkdir -p $OUT; R=$OUT/result.txt
PSQL="$PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q postgres"
bash /tmp/pgc.sh $X $N $PORT init || exit 1
sed -i 's/^shared_buffers = 4GB/shared_buffers = 2GB/' /nvme/fp/d-$N/postgresql.conf
echo "pg_fts.pending_flush_threshold = $FT" >> /nvme/fp/d-$N/postgresql.conf
bash /tmp/pgc.sh $X $N $PORT start || exit 1
$PSQL -f /tmp/setup.sql
$PSQL -c "INSERT INTO ag (n, tree_hash, message) SELECT n, hash, message FROM src WHERE n <= 20000"
$PSQL -c "CREATE INDEX idx_ag_msg_fts ON ag USING fts (to_ftsdoc('english', message)) $RO"
echo "built $(date -u +%T) ext $($PSQL -At -c "select extversion from pg_extension where extname='pg_fts'") W=$W abort=$AB np=$NP vac=$VE ovs=$OVS thr=$FT ro='$RO' cycles=$CY" >> $R
vacloop() { while [ -f $OUT/loading ]; do sleep $VE; $PSQL -c "VACUUM ag" >> $OUT/vac.log 2>&1; done; }
for cy in $(seq 1 $CY); do
  touch $OUT/loading; vacloop & VP=$!
  bash /tmp/load2.sh $PFX $PORT 1 $NP $W $AB $OUT $OVS
  rm -f $OUT/loading; wait $VP
  echo "cycle $cy loaded $(date -u +%T)" >> $R
  # free and reuse: delete nothing, but the aborted batches leave dead tuples; VACUUM twice then refill with
  # rows that match none of the probe terms
  $PSQL -c "VACUUM ag" -c "VACUUM ag"
  $PSQL -c "INSERT INTO ag (n, tree_hash, message) SELECT -g, 'x', 'zzfiller qqfiller ' || g FROM generate_series(1, 200000) g"
  bash /tmp/diff.sh $PFX $PORT "$N cycle $cy" $R
done
echo ARM_DONE >> $R
