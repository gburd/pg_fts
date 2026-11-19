#!/bin/bash
# ab180.sh: sparsemap 5.8.5 vs 5.9.0 inside pg_fts, PG 18.7, c6id.metal.  Arms (the .so swapped on one index):
#   v170   = the v1.17.0 PGXN zip (sha-checked; sparsemap 5.8.5)
#   v170b  = the same zip built again (A/A)
#   sm590  = v1.17.0 + vendor/sm.{c,h} from sparsemap 5.9.0 only (isolates the library)
#   v180   = the release branch (sparsemap 5.9.0 + the autovacuum-ring fix + version bump)
# State: 1.9M rows (40-160 tokens, log-uniform 200k vocabulary; 'remove' 6%, 'vacuum' 1%, 'patch' 0.5%),
# doclen_sidecar = off, one packed segment, then 1/80 of the rows deleted and VACUUMed: 23,750 scattered
# tombstones, the state where every ranked/count lookup consults the tombstone sparsemap.
# Q: ranked top-10 / top-200 and count(*), median of 11 per sample (each sample = one psql session of 14
#    statements, first 3 warm), 6 ABBA rounds.  CORR: ids/count md5 must be identical across arms first.
# VAC: VACUUM after the same 1/80 delete on a fresh index, per arm (v170 vs v180, sm590), 3 reps alternated.
set -u
M=18; O=/nvme/ab180; mkdir -p $O; exec > $O/ab180.log 2>&1; cd $O
S=$(sha256sum pg_fts-1.17.0.zip | cut -c1-64); [ "$S" = a93a86d5312aa67399833a2855cb807e2db87c34102679ac2479793e95ab6fc7 ] || { echo ZIP SHA MISMATCH; exit 1; }
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir)
for L in v170 v170b sm590 v180; do SRC=$O/src-$L; [ -d $SRC ] && continue; mkdir -p $SRC
  case $L in v170|v170b) (cd $SRC && unzip -q $O/pg_fts-1.17.0.zip && mv pg_fts-1.17.0/* .) ;; sm590) tar xzf $O/sm590only.tgz -C $SRC ;; v180) tar xzf $O/branch.tgz -C $SRC ;; esac
  (cd $SRC && make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo BUILD FAIL $L; exit 1; }; cp $SRC/pg_fts.so $O/pg_fts-$L.so; done
(cd $O/src-v170 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)   # 1.17.0 SQL objects; the .so is swapped
echo "so md5: $(for L in v170 v170b sm590 v180; do echo -n "$L $(md5sum < $O/pg_fts-$L.so | cut -c1-8) "; done)"
echo "sm versions: $(for L in v170 sm590 v180; do echo -n "$L $(grep -o 'SM_VERSION_STRING "[0-9.]*"' $O/src-$L/vendor/sm.h) "; done)"
D=$O/data; P=6418; ROWS=1900000
[ -d $D ] && { $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; mv $D $O/trash_$RANDOM; }
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=16GB\nmaintenance_work_mem=4GB\njit=off\nmax_parallel_workers_per_gather=0\nmax_parallel_maintenance_workers=0\nautovacuum=off\nmax_wal_size=32GB\n" >> $D/postgresql.conf
PS="numactl --physcpubind=14-15 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so; numactl --physcpubind=4-11 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; }
use v170
$PS -v ON_ERROR_STOP=1 -At -c "CREATE EXTENSION pg_fts" -c "SELECT setseed(0.31)" \
  -c "CREATE TABLE ag (id bigint PRIMARY KEY, head text, own text) WITH (autovacuum_enabled = off)" \
  -c "INSERT INTO ag SELECT g, 'msg ' || g, (SELECT string_agg('w' || floor(exp(random() * ln(200000)))::int, ' ') FROM generate_series(1, 40 + (g % 7) * 20) WHERE g > 0) || CASE WHEN random() < 0.06 THEN ' remove' ELSE '' END || CASE WHEN random() < 0.01 THEN ' vacuum' ELSE '' END || CASE WHEN random() < 0.005 THEN ' patch' ELSE '' END FROM generate_series(1, $ROWS) g" \
  -c "CREATE TABLE mvsave AS SELECT * FROM ag WHERE id % 80 = 0" -c "CHECKPOINT" >/dev/null || { echo SETUP FAIL; exit 1; }
echo "rows $($PS -At -c 'SELECT count(*) FROM ag')"
vac() { # $1 arm $2 rep : fresh index, delete the same 1/80, VACUUM (timed), put the rows back
  use $1
  $PS -At -c "DROP INDEX IF EXISTS ag_fts" -c "CREATE INDEX ag_fts ON ag USING fts (to_ftsdoc('english', head || ' ' || own)) WITH (doclen_sidecar = off)" -c "SELECT fts_vacuum('ag_fts')" -c "DELETE FROM ag WHERE id % 80 = 0" >/dev/null
  t0=$(date +%s.%N); $PS -At -c "VACUUM ag" >/dev/null; t1=$(date +%s.%N)
  echo "VAC arm=$1 rep=$2 vacuum_s=$(echo "$t1 - $t0" | bc) stats=[$($PS -At -c "SELECT ndocs || ' ' || round(avgdl::numeric,3) FROM fts_index_stats('ag_fts')")]"
  $PS -At -c "INSERT INTO ag SELECT * FROM mvsave" -c "VACUUM ag" >/dev/null
}
for rep in 1 2 3; do
  if [ $((rep % 2)) = 1 ]; then ORD="v170 sm590 v180"; else ORD="v180 sm590 v170"; fi
  for a in $ORD; do vac $a $rep; done; done
# Q state: built by v170 (5.8.5 writes the tombstone blob; every arm then reads it -- the upgrade case too)
use v170
$PS -At -c "DROP INDEX IF EXISTS ag_fts" -c "CREATE INDEX ag_fts ON ag USING fts (to_ftsdoc('english', head || ' ' || own)) WITH (doclen_sidecar = off)" -c "SELECT fts_vacuum('ag_fts')" -c "DELETE FROM ag WHERE id % 80 = 0" -c "VACUUM ag" >/dev/null
echo "Q state: nseg=$($PS -At -c "SELECT fts_index_nsegments('ag_fts')") $($PS -At -c "SELECT 'tombstones=' || sum(ndeleted) FROM fts_index_segments('ag_fts')")"
rk() { echo "SELECT id FROM ag WHERE to_ftsdoc('english', head || ' ' || own) @@@ to_ftsquery('english', '$1') ORDER BY to_ftsdoc('english', head || ' ' || own) <=> to_ftsquery('english', '$1') LIMIT $2;"; }
ct() { echo "SELECT count(*) FROM ag WHERE to_ftsdoc('english', head || ' ' || own) @@@ to_ftsquery('english', '$1');"; }
ids() { $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT md5(string_agg(id::text, ',')) FROM ($(rk $1 $2 | sed 's/;$//')) s"; }
for L in v170 sm590 v180; do use $L; for q in "patch 10" "vacuum 200" "remove 200"; do set -- $q; echo "CORR $L [$1 $2] $(ids $1 $2)"; done
  echo "CORR $L [count remove] $($PS -At -c "$(ct remove)")"; done
t() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; if [ "$1" = count ]; then ct $2; else rk $1 $2; fi; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
for r in 1 2 3 4 5 6; do
  if [ $((r % 2)) = 1 ]; then ORD="v170 sm590 v180 v170b v170b v180 sm590 v170"; else ORD="v170b v180 sm590 v170 v170 sm590 v180 v170b"; fi
  for L in $ORD; do use $L; sleep 2; echo "T round=$r so=$L patch10=$(t patch 10) vacuum200=$(t vacuum 200) remove200=$(t remove 200) count_remove=$(t count remove)"; done; done
$B/pg_ctl -D $D -w stop >/dev/null; echo AB180_DONE
