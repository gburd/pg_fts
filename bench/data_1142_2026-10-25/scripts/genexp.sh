#!/bin/bash
# genexp.sh <test>: run one REGRESS test with pg_regress on 1.14.1/PG18 and on the mutant; save results
T=$1
for X in pg18-v1141:5541:src-v1141-pg18 pg18-mut:5542:src-mut-pg18; do
  IFS=: read PX P S <<< "$X"; N=ge-$PX
  bash /tmp/pgc.sh $PX $N $P init >/dev/null; sed -i 's/^shared_buffers = 4GB/shared_buffers = 256MB/' /nvme/fp/d-$N/postgresql.conf
  bash /tmp/pgc.sh $PX $N $P start >/dev/null
  cd /nvme/fp/$S; cp /tmp/$T.sql sql/; touch expected/$T.out
  make installcheck PG_CONFIG=/nvme/fp/$PX/bin/pg_config PGHOST=/tmp PGPORT=$P PGUSER=postgres REGRESS="pg_fts $T" ISOLATION= PROVE_TESTS=ci/noop.pl > /nvme/fp/ge-$PX.log 2>&1
  cp results/$T.out /nvme/fp/ge-$PX-$T.out
  bash /tmp/pgc.sh $PX $N $P stop >/dev/null
done
diff /nvme/fp/ge-pg18-v1141-$T.out /nvme/fp/ge-pg18-mut-$T.out; echo "diff rc=$?"
