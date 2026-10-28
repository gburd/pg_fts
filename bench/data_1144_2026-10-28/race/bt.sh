#!/bin/bash
# bt.sh <tgz> <label> <hooks 0|1> [PROVE_TESTS] : build the tree for PG17 + PG18 into /nvme/rm/pfx<M>-<label>
# (fresh copy of /nvme/pg<M>), run REGRESS+ISOLATION installcheck and the given TAP tests. Prints one line per step.
TGZ=$1; L=$2; H=$3; TAPS=${4:-}
for M in 17 18; do
  PFX=/nvme/rm/pfx$M-$L; [ -d $PFX ] || cp -a /nvme/pg$M $PFX; B=$PFX/bin
  T=/nvme/rm/src$M-$L; [ -d $T ] && mv $T /nvme/trash_bt_$RANDOM; mkdir -p $T; tar xzf $TGZ -C $T; cd $T
  CO=""; [ "$H" = 1 ] && CO="COPT=-DPG_FTS_TEST_HOOKS"
  make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1
  W=$(make -s -j32 PG_CONFIG=$B/pg_config $CO 2>&1 | grep -E "warning:|error:" | head -3)
  make -s install PG_CONFIG=$B/pg_config $CO >/dev/null 2>&1 || { echo "PG$M $L INSTALL_FAIL"; continue; }
  echo "PG$M $L tree $(cat GITREV) hooks=$H so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) warnings: ${W:-none}"
  D=/nvme/rm/d$M-$L; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_bt_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  P=59$M; [ "$H" = 1 ] && P=60$M
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=512MB\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  if [ "$H" = 1 ]; then echo "PG$M $L installcheck skipped (hooks build prints a WARNING on load)"; $B/pg_ctl -D $D -w stop >/dev/null; else
  make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=$P PGUSER=postgres PROVE_TESTS=ci/noop.pl > /nvme/rm/ic$M-$L.log 2>&1; rc=$?
  echo "PG$M $L installcheck rc=$rc $(grep -cE '^ok ' /nvme/rm/ic$M-$L.log) ok $(grep -cE '^not ok ' /nvme/rm/ic$M-$L.log) not-ok $(grep -E '^not ok' /nvme/rm/ic$M-$L.log | awk '{print $4}' | tr '\n' ' ')"
  [ -f regression.diffs ] && cp regression.diffs /nvme/rm/diffs$M-$L.txt
  $B/pg_ctl -D $D -w stop >/dev/null; fi
  if [ -n "$TAPS" ]; then
    mv tmp_check /nvme/trash_bt_$RANDOM 2>/dev/null
    make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS="$TAPS" > /nvme/rm/tap$M-$L.log 2>&1; rc=$?
    echo "PG$M $L tap rc=$rc $(grep -E '^t/.*(ok|FAIL|Dubious|skipped)|^Result' /nvme/rm/tap$M-$L.log | tr -s ' ' | tr '\n' ' ')"
    grep -E "Failed test|got:|expected:" /nvme/rm/tap$M-$L.log | head -8
  fi
done
echo BT_DONE
