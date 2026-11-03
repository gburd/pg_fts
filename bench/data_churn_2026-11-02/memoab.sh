#!/bin/bash
# memoab.sh: the per-backend tombstone memo, A/B at the S3 state with an A/A pair, interleaved, 12 samples per build.
# Builds: expd (bba830f), expd2 (bba830f again), memo (bba830f + memo).  One index, the .so swapped (same catalog).
# patch10 / vacuum200 / remove200 each a median of 11 after 3 warm; the memo is per backend, so each sample is one
# psql session running its 14 statements (the first pays the validation + checkpoint build in both builds).
set -u
M=18; O=/nvme/memoab; mkdir -p $O; exec > $O/memoab.log 2>&1; cd $O
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir)
for L in expd expd2 memo; do S=$O/src-$L; [ -d $S ] && continue; mkdir -p $S
  case $L in expd2) tar xzf /tmp/expd.tgz -C $S ;; *) tar xzf /tmp/$L.tgz -C $S ;; esac
  (cd $S && make -s -j16 PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo BUILD FAIL $L; exit 1; }; cp $S/pg_fts.so $O/pg_fts-$L.so; done
(cd $O/src-expd && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)
D=$O/data; P=6218; ROWS=1900000
[ -d $D ] || { $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=16GB\nmaintenance_work_mem=8GB\njit=off\nmax_parallel_workers_per_gather=0\nautovacuum=off\nmax_wal_size=32GB\n" >> $D/postgresql.conf; }
PS="numactl --physcpubind=16-17 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so; numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; }
use expd
sed -n '/^CREATE TABLE ag/,/^VACUUM ANALYZE ag;/p' /tmp/churn2.sh | sed "s/\$ROWS/$ROWS/g" > setup.sql
$PS -v ON_ERROR_STOP=1 -At -c "CREATE EXTENSION pg_fts" -c "SELECT setseed(0.31)" -f setup.sql >/dev/null || { echo SETUP FAIL; exit 1; }
base=$($PS -At -c "SELECT max(id) FROM ag")
for b in $(seq 0 23); do $PS -At -c "WITH mv AS (DELETE FROM ag WHERE id <= $ROWS AND id % 80 = 0 AND (id / 80) % 24 = $b RETURNING id, head, own) INSERT INTO ag SELECT $base + id, head, own FROM mv" >/dev/null; done
$PS -At -c "SET pg_fts.bestfirst = on" -c "SELECT 1" >/dev/null
# the S3 state WITHOUT fts_vacuum (it would now expunge): one segment by REINDEX before the moves is not possible
# after them, so pack first by fts_vacuum BEFORE the VACUUM (dead heap rows present: nothing tombstoned yet)
$PS -At -c "SELECT fts_vacuum('ag_fts')" >/dev/null; $PS -At -c "VACUUM ag" >/dev/null
echo "state: $($PS -At -c "SELECT 'nseg=' || fts_index_nsegments('ag_fts')")"
rk() { echo "SELECT id FROM ag WHERE to_ftsdoc('english', head || ' ' || own) @@@ to_ftsquery('english', '$1') ORDER BY to_ftsdoc('english', head || ' ' || own) <=> to_ftsquery('english', '$1') LIMIT $2;"; }
for L in expd memo; do use $L; for q in "patch 10" "vacuum 200" "remove 200"; do set -- $q
  echo "CORR $L [$1 $2] $($PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT md5(string_agg(id::text, ',')) FROM ($(rk $1 $2 | sed 's/;$//')) s")"; done; done
t() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; rk $1 $2; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
first() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; echo "\\o /dev/null"; rk $1 $2; echo "\\o"; } | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -1; }
for r in 1 2 3 4 5 6; do
  if [ $((r % 2)) = 1 ]; then ORD="expd memo expd2 expd2 memo expd"; else ORD="expd2 memo expd expd memo expd2"; fi
  for L in $ORD; do use $L; sleep 2; echo "T round=$r so=$L patch10=$(t patch 10) vacuum200=$(t vacuum 200) remove200=$(t remove 200) first_patch10=$(first patch 10)"; done; done
$B/pg_ctl -D $D -w stop >/dev/null; echo MEMOAB_DONE
