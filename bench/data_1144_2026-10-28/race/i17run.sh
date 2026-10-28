#!/bin/bash
# sql/count_partial.sql on a fresh build of the i17 tree (PG17 + PG18) and on 1.14.3 (control), outputs saved
exec > /nvme/rm/i17run.log 2>&1
for L in i17 v1143; do
  TGZ=/nvme/rm/i17.tgz; [ $L = v1143 ] && TGZ=/nvme/rm/v1143.tgz
  T=/nvme/rm/src-$L; [ -d $T ] && mv $T /nvme/trash_i17_$RANDOM; mkdir -p $T; tar xzf $TGZ -C $T
  for M in 17 18; do
    PX=$L; [ $L = i17 ] && PX=i19
    B=/nvme/rm/pfx$M-$PX/bin; D=/nvme/rm/d$M-$PX; P=61$M; [ $PX = i19 ] && P=62$M
    cd $T; make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
    $B/pg_ctl -D $D -l $D/log -w start >/dev/null
    $B/dropdb -h /tmp -p $P -U postgres --if-exists cp >/dev/null 2>&1; $B/createdb -h /tmp -p $P -U postgres cp
    $B/psql -X -a -q -h /tmp -p $P -U postgres -d cp < /nvme/rm/src-i17/sql/count_partial.sql > /nvme/rm/cp_${M}_$L.out 2>&1
    echo "PG$M $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8): f=$(grep -cE '\| f( |$)|^ f$' /nvme/rm/cp_${M}_$L.out) ERRORs=$(grep -c ERROR /nvme/rm/cp_${M}_$L.out)"
    $B/pg_ctl -D $D -w stop >/dev/null
  done
done
echo I17RUN_DONE
