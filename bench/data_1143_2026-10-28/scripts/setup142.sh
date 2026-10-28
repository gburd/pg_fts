#!/bin/bash
# Install v1.14.2 into private copies of PG17/PG18 and start a cluster each (ports 5717/5718).
set -uo pipefail
cd /nvme/iss
for M in 17 18; do
  P=/nvme/iss/pg$M-v1142
  [ -d $P ] || cp -a /nvme/pg$M $P
  S=/nvme/iss/src142_$M; [ -d $S ] && mv $S /nvme/trash_$RANDOM; mkdir -p $S; tar xzf /nvme/iss/iss_rel1142.tgz -C $S
  cd $S; [ -f pg_fts.control ] || cd */
  grep default_version pg_fts.control
  make -s clean PG_CONFIG=$P/bin/pg_config >/dev/null 2>&1
  make -s -j32 PG_CONFIG=$P/bin/pg_config 2>&1 | grep -E "warning:|error:" | head
  make -s install PG_CONFIG=$P/bin/pg_config >/dev/null 2>&1; echo "install rc=$?"
  D=/nvme/iss/d$M-v1142; $P/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_$RANDOM
  $P/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=57$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=1GB\n" >> $D/postgresql.conf
  $P/bin/pg_ctl -D $D -l $D/log -w start >/dev/null; echo "PG$M v1142 started rc=$?"
  cd /nvme/iss
done
echo SETUP142_DONE
