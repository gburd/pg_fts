#!/bin/bash
O=/nvme/mut; mkdir -p $O; B=/nvme/pg17; PFX=$O/pfx; [ -d $PFX ] || cp -a $B $PFX
S=$O/src; mkdir -p $S; tar xzf /tmp/mut.tgz -C $S
(cd $S && taskset -c 32-63 make -s -j16 PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1) || { echo BUILD FAIL; exit 1; }
D=$O/d; $PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=6917\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
numactl --cpunodebind=1 --membind=1 $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
numactl --cpunodebind=1 $PFX/bin/psql -X -a -q -h /tmp -p 6917 -U postgres -d postgres < /tmp/ranked_tombstones.sql > $O/rt_mut.out 2>&1
echo "GITREV=$(cat $S/GITREV) f_count=$(grep -cE '\| f( |$)|^ f$' $O/rt_mut.out)"; grep -A3 reused_rows_ranked $O/rt_mut.out | tail -2
$PFX/bin/pg_ctl -D $D -w stop >/dev/null
