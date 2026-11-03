#!/bin/bash
# churn.sh: reproduce "ranked top-k 60-300x slower after delete+insert churn" (2026-11-02 report).
# Hypothesis under test: after the LAST fts_vacuum a heap VACUUM tombstones scattered docids; the tombstone sparsemap
# then has ~one chunk per deleted row, and per-posting sm_contains lookups that land in gaps between chunks
# head-walk the chunk list.  Steps (each measured: ranked top-200 / top-10, fts_search direct, count(*)):
#  S0 fresh build; S1 delete 1/80 rows scattered + insert them again under new ids (24 txns) ; S2 fts_vacuum (pack, dead
#  heap rows still present) ; S3 VACUUM (bulkdelete -> tombstones on the packed segment: the production end state) ;
#  S4 fts_vacuum again (the reporter's copy; measured: the single packed segment and its tombstones stay) ; S5 S1..S3 again ; S6 REINDEX.
set -u
M=${PGMAJ:-18}; O=/nvme/churn2; mkdir -p $O; exec > $O/churn$SFX.log 2>&1; cd $O
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir)
SO=${SO:-head}; S=$O/src-$SO; if [ ! -d $S ]; then mkdir -p $S; tar xzf /tmp/$SO.tgz -C $S; fi
(cd $S && make -s -j16 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo BUILD FAIL; exit 1; }
echo "so=$SO GITREV=$(cat $S/GITREV) md5=$(md5sum $LIB/pg_fts.so | cut -c1-8)"
D=$O/data$SFX; P=60$M
for d in $O/data*; do [ -d $d ] && { $B/pg_ctl -D $d -m immediate -w stop >/dev/null 2>&1; mv $d $O/trash_$RANDOM; }; done
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=16GB\nmaintenance_work_mem=8GB\njit=off\nmax_parallel_workers_per_gather=0\nautovacuum=off\nmax_wal_size=32GB\n" >> $D/postgresql.conf
numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null || { echo START FAIL; exit 1; }
PS="numactl --physcpubind=16-17 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
ROWS=${ROWS:-1900000}
$PS -At -v ON_ERROR_STOP=1 <<SQL || { echo SETUP FAIL; exit 1; }
SET client_min_messages = warning;
CREATE EXTENSION pg_fts;
SELECT setseed(0.31);
-- ~150 tokens per row, heavy-tailed vocabulary (log-uniform over w1..w200000); 'remove' in ~6% of rows,
-- 'vacuum' ~1%, 'patch' ~0.5%
CREATE TABLE ag (id bigint PRIMARY KEY, head text, own text);
INSERT INTO ag SELECT g, 'msg ' || g,
  (SELECT string_agg('w' || floor(exp(random() * ln(200000)))::int, ' ') FROM generate_series(1, 150) WHERE g > 0)
  || CASE WHEN random() < 0.06 THEN ' remove' ELSE '' END || CASE WHEN random() < 0.01 THEN ' vacuum' ELSE '' END
  || CASE WHEN random() < 0.005 THEN ' patch' ELSE '' END
  FROM generate_series(1, $ROWS) g;
CREATE INDEX ag_fts ON ag USING fts (to_ftsdoc('english', head || ' ' || own)) WITH (doclen_sidecar = off);
VACUUM ANALYZE ag;
SELECT 'rows=' || count(*) || ' heap_blocks=' || pg_relation_size('ag') / 8192 || ' index=' || pg_size_pretty(pg_relation_size('ag_fts')) FROM ag;
SQL
rk() { echo "SELECT id FROM ag WHERE to_ftsdoc('english', head || ' ' || own) @@@ to_ftsquery('english', '$1') ORDER BY to_ftsdoc('english', head || ' ' || own) <=> to_ftsquery('english', '$1') LIMIT $2;"; }
med() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq $3); do echo "\\o /dev/null"; echo "$1"; echo "\\o"; done; } \
        | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -$(( $3 - 1 )) | sort -n | awk '{a[NR]=$1} END {printf "%s", a[int((NR+1)/2)]}'; }
stage() {
  local st=$($PS -At -c "SELECT 'nseg=' || fts_index_nsegments('ag_fts') || ' ' || (SELECT 'ndocs=' || ndocs FROM fts_index_stats('ag_fts'))")
  local ids=$($PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT md5(string_agg(id::text, ',')) FROM ($(rk remove 200 | sed 's/;$//')) s")
  local rm=$(med "$(rk remove 200)" 0 6) vc=$(med "$(rk vacuum 200)" 0 6) pt=$(med "$(rk patch 10)" 0 6)
  local fs=$(med "SELECT count(*) FROM fts_search('ag_fts', to_ftsquery('english', 'remove'), 200);" 0 6)
  local n=$($PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT count(*) FROM ($(rk remove 200 | sed 's/;$//')) s")
  local ct=$($PS -At -c "SET enable_seqscan=off" -c "SET enable_indexscan=off" -c "\\timing on" -c "SELECT count(*) FROM ag WHERE to_ftsdoc('english', head || ' ' || own) @@@ to_ftsquery('english', 'vacuum')" 2>&1 | tr '\n' ' ')
  echo "STAGE $1: $st remove_rows=$n top200md5=${ids:0:8} remove200=${rm}ms vacuum200=${vc}ms patch10=${pt}ms fts_search_remove200=${fs}ms count_vacuum=[$ct]"
}
stage S0_fresh
churn() { # move every 80th original row (residue $1; scattered over the whole heap) to a new id, 24 transactions
  local base=$($PS -At -c "SELECT max(id) FROM ag")
  for b in $(seq 0 23); do
    $PS -At -c "WITH mv AS (DELETE FROM ag WHERE id <= $ROWS AND id % 80 = $1 AND (id / 80) % 24 = $b RETURNING id, head, own)
                INSERT INTO ag SELECT $base + id, head, own FROM mv" >/dev/null
  done
  echo "  churn moved $($PS -At -c "SELECT count(*) FROM ag WHERE id > $base") rows"
}
churn 0; stage S1_after_churn
$PS -At -c "SELECT fts_vacuum('ag_fts')" >/dev/null; stage S2_fts_vacuum_dead_heap_present
$PS -At -c "VACUUM ag" >/dev/null; stage S3_VACUUM_tombstones_PROD_STATE
t0=$(date +%s.%N); did=$($PS -At -c "SELECT fts_vacuum('ag_fts')"); t1=$(date +%s.%N); echo "  fts_vacuum returned $did in $(echo "$t1 - $t0" | bc) s, index $($PS -At -c "SELECT pg_size_pretty(pg_relation_size('ag_fts'))")"; stage S4_fts_vacuum_again_COPY_STATE
churn 41; $PS -At -c "SELECT fts_vacuum('ag_fts')" >/dev/null; $PS -At -c "VACUUM ag" >/dev/null; stage S5_second_cycle_PROD_STATE
t0=$(date +%s.%N); $PS -At -c "REINDEX INDEX ag_fts" >/dev/null; t1=$(date +%s.%N); echo "  REINDEX in $(echo "$t1 - $t0" | bc) s, index $($PS -At -c "SELECT pg_size_pretty(pg_relation_size('ag_fts'))")"; stage S6_REINDEX
$B/pg_ctl -D $D -w stop >/dev/null
echo CHURN_DONE
