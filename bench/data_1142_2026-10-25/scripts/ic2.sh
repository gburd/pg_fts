#!/bin/bash
# installcheck (REGRESS+ISOLATION) of the final tree on PG 17 and 18
G=/nvme/fp/gate
for M in 17 18; do
  B=/nvme/pg$M/bin; T=$G/ftree$M; [ -d $T ] && mv $T /nvme/trash_g_$RANDOM; mkdir -p $T; tar xzf /nvme/fp/final.tgz -C $T; cd $T
  make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s PG_CONFIG=$B/pg_config -j32 2>&1 | grep -E "warning:|error:" | head; make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
  D=$G/frg$M; [ -d $D ] && mv $D /nvme/trash_g_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=558$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=512MB\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=558$M PGUSER=postgres PROVE_TESTS=ci/noop.pl > $G/fic$M.log 2>&1
  echo "PG$M tree $(cat GITREV): $(grep -cE '^ok ' $G/fic$M.log) ok, $(grep -cE '^not ok ' $G/fic$M.log) not ok; $(grep -E 'tests passed|tests failed' $G/fic$M.log | tr '\n' ' ') check-ascii: $(make -s check-ascii PG_CONFIG=$B/pg_config 2>&1 | tail -1)"
  $B/pg_ctl -D $D -w stop >/dev/null
done
echo IC2_DONE
