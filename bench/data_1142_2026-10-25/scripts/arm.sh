#!/bin/bash
# arm.sh <name> <prefix-name> <port> plain|upg <W> <abort_pct> <npasses>
N=$1; X=$2; PORT=$3; MODE=$4; W=$5; AB=$6; NP=$7
PFX=/nvme/fp/$X; OUT=/nvme/fp/out-$N; mkdir -p $OUT; R=$OUT/result.txt
PSQL="$PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q postgres"
bash /tmp/pgc.sh $X $N $PORT init && bash /tmp/pgc.sh $X $N $PORT start || exit 1
$PSQL -f /tmp/setup.sql
$PSQL -c "COPY ag (n, tree_hash, message) FROM '/nvme/fp/commits.tsv'"
$PSQL -c "CREATE INDEX idx_ag_msg_fts ON ag USING fts (to_ftsdoc('english', message))"
echo "built $(date -u +%T) ext $($PSQL -At -c "select extversion from pg_extension where extname='pg_fts'")" >> $R
vacloop() { while [ -f $OUT/loading ]; do sleep 30; $PSQL -c "VACUUM ag" >> $OUT/vac.log 2>&1; done; }
phase() { # lo hi
  touch $OUT/loading; vacloop & VP=$!
  bash /tmp/load.sh $PFX $PORT $1 $2 $W $AB $OUT
  rm -f $OUT/loading; wait $VP
  echo "loaded passes $1-$2 $(date -u +%T)" >> $R
}
if [ $MODE = upg ]; then
  H=$((NP/2))
  phase 1 $H
  bash /tmp/diff.sh $PFX $PORT "$N on-1.10.0" $R
  bash /tmp/pgc.sh $X $N $PORT stop
  cp /nvme/fp/pg18-v1141/lib/postgresql/pg_fts.so $PFX/lib/postgresql/
  cp /nvme/fp/pg18-v1141/share/postgresql/extension/pg_fts* $PFX/share/postgresql/extension/
  bash /tmp/pgc.sh $X $N $PORT start
  $PSQL -c "ALTER EXTENSION pg_fts UPDATE"
  bash /tmp/diff.sh $PFX $PORT "$N upgraded-to-1.14.1" $R
  phase $((H+1)) $NP
else
  phase 1 $NP
fi
sleep 60
bash /tmp/diff.sh $PFX $PORT "$N final" $R
echo ARM_DONE >> $R
