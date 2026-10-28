#!/bin/bash
# run sql/ranked_driven_and.sql (from the i19 tree) on the 1.14.3 build and the i19 build, PG17 + PG18; save outputs
exec > /nvme/rm/i19run.log 2>&1
for L in i19 v1143; do
  TGZ=/nvme/rm/$L.tgz; T=/nvme/rm/src-$L; [ -d $T ] && mv $T /nvme/trash_i19_$RANDOM; mkdir -p $T; tar xzf $TGZ -C $T
  for M in 17 18; do
    PFX=/nvme/rm/pfx$M-$L; [ -d $PFX ] || cp -a /nvme/pg$M $PFX; B=$PFX/bin
    cd $T; make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
    D=/nvme/rm/d$M-$L; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_i19_$RANDOM
    $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1; P=61$M; [ $L = i19 ] && P=62$M
    printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=512MB\n" >> $D/postgresql.conf
    $B/pg_ctl -D $D -l $D/log -w start >/dev/null; $B/createdb -h /tmp -p $P -U postgres rd
    $B/psql -X -a -q -h /tmp -p $P -U postgres -d rd < /nvme/rm/src-i19/sql/ranked_driven_and.sql > /nvme/rm/rd_${M}_$L.out 2>&1
    echo "PG$M $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8): f count=$(grep -cE '\| f( |$)|^ f$' /nvme/rm/rd_${M}_$L.out) ERRORs=$(grep -c ERROR /nvme/rm/rd_${M}_$L.out)"
    $B/pg_ctl -D $D -w stop >/dev/null
  done
done
echo I19RUN_DONE
