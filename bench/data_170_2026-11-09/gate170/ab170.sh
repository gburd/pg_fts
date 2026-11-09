#!/bin/bash
# ab170.sh: pg_fts 1.16.0 (v1.16.0 zip) vs 1.17.0 (final.tgz) on PG 18.6, c6id.metal.  The 1.17.0 change is in
# bulkdelete (dead-length walk: a second dictionary walk for inline segments), merge and corpus statistics, so:
#   VAC  VACUUM wall time after the same scattered delete (1.9M rows, 1/80 deleted = 23.7k, one packed segment),
#        per arm on its OWN freshly built copy, sidecar off (v3: the walk) and on (v4: sidecar read), 3 reps each;
#   Q    ranked top-10/top-200 latency on the post-VACUUM state, the .so swapped on one index (median of 11 per
#        sample, 6 rounds, ABBA, an A/A pair), each sample its own psql session;
#   CORR top-200 ids on each arm vs a REINDEX of the same rows (1.17.0 must equal it; 1.16.0 is expected to differ).
# Inputs in /nvme/ab170: v160.zip (sha-checked), final.tgz.
set -u
M=18; O=/nvme/ab170; mkdir -p $O; exec > $O/ab170.log 2>&1; cd $O
S=$(sha256sum v160.zip | cut -c1-64); [ "$S" = 591c2f8fd836c63f13c2c4e0ffec51709406c9276dae1493f454094f4ad2f2db ] || { echo ZIP SHA MISMATCH; exit 1; }
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir); SH=$($B/pg_config --sharedir)/extension
for L in v160 v170 v170b; do SRC=$O/src-$L; [ -d $SRC ] && continue; mkdir -p $SRC
  case $L in v160) (cd $SRC && unzip -q $O/v160.zip && mv pg_fts-1.16.0/* .) ;; *) tar xzf $O/final.tgz -C $SRC ;; esac
  (cd $SRC && make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo BUILD FAIL $L; exit 1; }; cp $SRC/pg_fts.so $O/pg_fts-$L.so; done
(cd $O/src-v170 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)   # 1.17.0 SQL objects; the .so is swapped
echo "so md5: v160 $(md5sum < $O/pg_fts-v160.so | cut -c1-8) v170 $(md5sum < $O/pg_fts-v170.so | cut -c1-8) v170b $(md5sum < $O/pg_fts-v170b.so | cut -c1-8); markers v170: $(grep -c bm25_segment_dead_doclen $O/src-v170/pg_fts_am.c) v160: $(grep -c bm25_segment_dead_doclen $O/src-v160/pg_fts_am.c)"
D=$O/data; P=6318; ROWS=1900000
[ -d $D ] && { $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; mv $D $O/trash_$RANDOM; }
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=16GB\nmaintenance_work_mem=4GB\njit=off\nmax_parallel_workers_per_gather=0\nmax_parallel_maintenance_workers=0\nautovacuum=off\nmax_wal_size=32GB\n" >> $D/postgresql.conf
PS="numactl --physcpubind=14-15 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so; numactl --physcpubind=4-11 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; }
use v170
$PS -v ON_ERROR_STOP=1 -At -c "CREATE EXTENSION pg_fts" -c "SELECT setseed(0.31)" \
  -c "CREATE TABLE ag (id bigint PRIMARY KEY, head text, own text) WITH (autovacuum_enabled = off)" \
  -c "INSERT INTO ag SELECT g, 'msg ' || g, (SELECT string_agg('w' || floor(exp(random() * ln(200000)))::int, ' ') FROM generate_series(1, 40 + (g % 7) * 20) WHERE g > 0) || CASE WHEN random() < 0.06 THEN ' remove' ELSE '' END || CASE WHEN random() < 0.01 THEN ' vacuum' ELSE '' END || CASE WHEN random() < 0.005 THEN ' patch' ELSE '' END FROM generate_series(1, $ROWS) g" \
  -c "CHECKPOINT" >/dev/null || { echo SETUP FAIL; exit 1; }
echo "rows $($PS -At -c 'SELECT count(*) FROM ag')"
# VAC: per arm, per sidecar setting, 3 reps: build a fresh index, delete the same 1/80 scattered rows, VACUUM (timed),
# then re-insert them (so the next rep deletes the same set from the same heap)
vac() { # $1 arm $2 sc $3 rep
  use $1
  $PS -At -c "DROP INDEX IF EXISTS ag_fts" -c "CREATE INDEX ag_fts ON ag USING fts (to_ftsdoc('english', head || ' ' || own)) WITH (doclen_sidecar = $2)" -c "SELECT fts_vacuum('ag_fts')" >/dev/null
  $PS -At -c "CREATE TABLE IF NOT EXISTS mvsave AS SELECT * FROM ag WHERE id % 80 = 0" -c "DELETE FROM ag WHERE id % 80 = 0" >/dev/null
  t0=$(date +%s.%N); $PS -At -c "VACUUM ag" >/dev/null; t1=$(date +%s.%N)
  st=$($PS -At -c "SELECT ndocs || ' ' || round(avgdl::numeric,3) FROM fts_index_stats('ag_fts')")
  tr=$($PS -At -c "SELECT count(*) || ' ' || round(avg(ftsdoc_length(to_ftsdoc('english', head || ' ' || own)))::numeric,3) FROM ag")
  echo "VAC arm=$1 sc=$2 rep=$3 vacuum_s=$(echo "$t1 - $t0" | bc) stats=[$st] truth=[$tr]"
  $PS -At -c "INSERT INTO ag SELECT * FROM mvsave" -c "VACUUM ag" >/dev/null
}
for rep in 1 2 3; do for sc in off on; do
  if [ $((rep % 2)) = 1 ]; then for a in v160 v170; do vac $a $sc $rep; done; else for a in v170 v160; do vac $a $sc $rep; done; fi
done; done
# Q: one index (sidecar off, the reporter's setting) at the post-VACUUM state, built + VACUUMed by v170
use v170
$PS -At -c "DROP INDEX IF EXISTS ag_fts" -c "CREATE INDEX ag_fts ON ag USING fts (to_ftsdoc('english', head || ' ' || own)) WITH (doclen_sidecar = off)" -c "SELECT fts_vacuum('ag_fts')" -c "DELETE FROM ag WHERE id % 80 = 0" -c "VACUUM ag" >/dev/null
echo "Q state: nseg=$($PS -At -c "SELECT fts_index_nsegments('ag_fts')") $($PS -At -c "SELECT 'tombstones=' || sum(ndeleted) FROM fts_index_segments('ag_fts')") stats=$($PS -At -c "SELECT ndocs || ' ' || round(avgdl::numeric,3) FROM fts_index_stats('ag_fts')")"
rk() { echo "SELECT id FROM ag WHERE to_ftsdoc('english', head || ' ' || own) @@@ to_ftsquery('english', '$1') ORDER BY to_ftsdoc('english', head || ' ' || own) <=> to_ftsquery('english', '$1') LIMIT $2;"; }
ids() { $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT md5(string_agg(id::text, ',')) FROM ($(rk $1 $2 | sed 's/;$//')) s"; }
for L in v160 v170; do use $L; for q in "patch 10" "vacuum 200" "remove 200"; do set -- $q; echo "CORR $L [$1 $2] $(ids $1 $2)"; done; done
t() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; rk $1 $2; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
for r in 1 2 3 4 5 6; do
  if [ $((r % 2)) = 1 ]; then ORD="v160 v170 v170b v170b v170 v160"; else ORD="v170b v170 v160 v160 v170 v170b"; fi
  for L in $ORD; do use $L; sleep 2; echo "T round=$r so=$L patch10=$(t patch 10) vacuum200=$(t vacuum 200) remove200=$(t remove 200)"; done; done
# CORR vs REINDEX of the same rows (on v170)
use v170; $PS -At -c "REINDEX INDEX ag_fts" >/dev/null
for q in "patch 10" "vacuum 200" "remove 200"; do set -- $q; echo "CORR reindex [$1 $2] $(ids $1 $2)"; done
$B/pg_ctl -D $D -w stop >/dev/null; echo AB170_DONE
