#!/bin/bash
# r1.sh: run jimdawdy-hub's bmw_block_end test (e4bba08) against a pg_fts build on its own cluster (PG17 + PG18).
# $1 = tree tgz, $2 = label.  Result: the diff against the fork's expected output (empty = pass).
set -u
T=$1; L=$2; O=/nvme/r1; mkdir -p $O; cd $O
for M in 17 18; do
  B=/nvme/pg$M/bin; S=$O/src-$L-$M; [ -d $S ] || { mkdir -p $S; tar xzf $T -C $S; }
  PFX=$O/pfx$M-$L; [ -d $PFX ] || cp -a /nvme/pg$M $PFX
  (cd $S && make -s -j16 PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1) || { echo "BUILD FAIL $L $M"; continue; }
  D=$O/d$M-$L; case $L in fix) P=64$M;; v111) P=66$M;; v113) P=67$M;; *) P=63$M;; esac
  [ -d $D ] && { $PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; mv $D $O/trash_$RANDOM; }
  $PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
  $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  $PFX/bin/psql -X -q -h /tmp -p $P -U postgres -d postgres -c "CREATE EXTENSION pg_fts" >/dev/null
  $PFX/bin/psql -X -a -q -h /tmp -p $P -U postgres -d postgres < /tmp/bmw_block_end.sql > $O/out_${L}_${M}.txt 2>&1
  echo "== PG$M $L so=$(md5sum $PFX/lib/postgresql/pg_fts.so 2>/dev/null | cut -c1-8) GITREV=$(cat $S/GITREV)"
  diff /tmp/bmw_block_end.out $O/out_${L}_${M}.txt | head -30; echo "  diff_rc=${PIPESTATUS[0]}"
  grep -A3 "ref_top1\|index_top1" $O/out_${L}_${M}.txt | grep -E "^ +[0-9]+$" | tr '\n' ' '; echo
  $PFX/bin/pg_ctl -D $D -w stop >/dev/null
done
