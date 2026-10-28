#!/bin/bash
# bld.sh <tgz> <label> <portprefix> : build+install a pg_fts tree into private PG17/PG18 copies, (re)start clusters
set -uo pipefail
TGZ=$1; L=$2; PP=$3
for M in 17 18; do
  P=/nvme/iss/pg$M-$L
  [ -d $P ] || cp -a /nvme/pg$M $P
  S=/nvme/iss/src_${L}_$M; [ -d $S ] && mv $S /nvme/trash_$RANDOM; mkdir -p $S; tar xzf $TGZ -C $S; cd $S
  make -s clean PG_CONFIG=$P/bin/pg_config >/dev/null 2>&1
  make -s -j32 PG_CONFIG=$P/bin/pg_config 2>&1 | grep -E "warning:|error:" | head
  make -s install PG_CONFIG=$P/bin/pg_config >/dev/null 2>&1; echo "PG$M $L install rc=$? so=$(md5sum $P/lib/pg_fts.so | cut -c1-8) ver=$(grep default_version pg_fts.control)"
  D=/nvme/iss/d$M-$L
  if [ -d $D ]; then $P/bin/pg_ctl -D $D -w restart -l $D/log >/dev/null; echo "PG$M $L restarted rc=$?"; else
    $P/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
    printf "port=$PP$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=1GB\n" >> $D/postgresql.conf
    $P/bin/pg_ctl -D $D -l $D/log -w start >/dev/null; echo "PG$M $L started rc=$?"; fi
done
