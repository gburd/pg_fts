#!/bin/bash
# prof.sh: perf profiles of the remaining costs on the FIX build.  P1 = S2 state (1 seg after churn+fts_vacuum, no
# tombstones) remove200; P2 = S3 state (tombstones) patch10 and remove200; P0 = fresh build remove200 (control).
set -u
M=18; O=/nvme/churn; exec > $O/prof.log 2>&1; cd $O
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir); ROWS=1900000
(cd $O/src-fix && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1); echo "so md5=$(md5sum $LIB/pg_fts.so | cut -c1-8)"
for d in $O/data*; do [ -d $d ] && { $B/pg_ctl -D $d -m immediate -w stop >/dev/null 2>&1; mv $d $O/trash_$RANDOM; }; done
D=$O/data_prof; P=6118
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=16GB\nmaintenance_work_mem=8GB\njit=off\nmax_parallel_workers_per_gather=0\nautovacuum=off\nmax_wal_size=32GB\n" >> $D/postgresql.conf
numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null || { echo START FAIL; exit 1; }
PS="$B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
sed -n '/^CREATE TABLE ag/,/^VACUUM ANALYZE ag;/p' $O/churn.sh | sed "s/\$ROWS/$ROWS/g" > setup.sql
$PS -v ON_ERROR_STOP=1 -At -c "CREATE EXTENSION pg_fts" -c "SELECT setseed(0.31)" -f setup.sql >/dev/null || { echo SETUP FAIL; exit 1; }
Q() { echo "SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT count(*) FROM (SELECT id FROM ag WHERE to_ftsdoc('english', head || ' ' || own) @@@ to_ftsquery('english', '$1') ORDER BY to_ftsdoc('english', head || ' ' || own) <=> to_ftsquery('english', '$1') LIMIT $2) s;"; }
prof() { # $1 label $2 term $3 k $4 reps: perf record the backend of one session running the query reps times
  local f=/tmp/q_$1.sql; { echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1);"; for i in $(seq $4); do Q $2 $3; done; } > $f
  $PS -At -f $f > /tmp/out_$1.txt 2>&1 &
  local cl=$!; sleep 0.5; local pid=$(head -1 /tmp/out_$1.txt)
  perf record -g -F 2000 -p $pid -o $O/perf_$1.data -- sleep $5 >/dev/null 2>&1; wait $cl
  echo "== $1 ($2 top-$3 x$4)"; perf report -i $O/perf_$1.data --no-children --stdio --percent-limit 3 2>/dev/null | grep -E "^ +[0-9]+\.[0-9]+%" | head -12
}
prof P0_fresh remove 200 40 4
base=$($PS -At -c "SELECT max(id) FROM ag")
for b in $(seq 0 23); do $PS -At -c "WITH mv AS (DELETE FROM ag WHERE id <= $ROWS AND id % 80 = 0 AND (id / 80) % 24 = $b RETURNING id, head, own) INSERT INTO ag SELECT $base + id, head, own FROM mv" >/dev/null; done
$PS -At -c "SELECT fts_vacuum('ag_fts')" >/dev/null
prof P1_S2_notomb remove 200 20 6
$PS -At -c "VACUUM ag" >/dev/null
prof P2_S3_patch10 patch 10 200 6
prof P2_S3_remove remove 200 20 7
$B/pg_ctl -D $D -w stop >/dev/null; echo PROF_DONE
