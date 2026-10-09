#!/bin/bash
# bench/PLAN_TPS_VARIANCE_2026-10-09.md, per host.  Expects comp_setup111.sh fts done (PG, corpus,
# /nvme/pg_fts_rel.so), and /tmp/mbench.c, /tmp/cluster3.sh, /tmp/tps2_110.sh.
set -uo pipefail
OUT=/nvme/tv; mkdir -p $OUT
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir)
P="$B/psql -h /tmp -U postgres -X -q -At"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-perf >/dev/null 2>&1
log "host=<host> kernel=$(uname -r) cpu=$(lscpu | sed -n 's/^Model name: *//p') nproc=$(nproc) thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled) numa_balancing=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)"
log "dmi: $(sudo cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null) $(sudo cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null | cut -c1-4)xx"
log "meminfo: $(grep -E 'MemTotal|HugePages_Total' /proc/meminfo | tr -s ' ' | tr '\n' ' ')"
# 1. host characterisation, idle host
cc -O2 -pthread /tmp/mbench.c -o /tmp/mbench && /tmp/mbench > $OUT/mbench.txt 2>&1; log "mbench: $(grep -v '^c2c_ns [0-9]' $OUT/mbench.txt | tr '\n' ' ')"
# cluster + index (release binary)
cp /nvme/pg_fts_rel.so $LIB/pg_fts.so
bash /tmp/cluster3.sh fts > $OUT/cluster.log 2>&1
$P -c "CREATE EXTENSION pg_fts" -c "CREATE EXTENSION pg_prewarm" >/dev/null
s=$(date +%s); $P -c "ALTER TABLE docs ADD COLUMN d ftsdoc" -c "UPDATE docs SET d = to_ftsdoc('english', content)" -c "VACUUM (FREEZE, ANALYZE) docs" >/dev/null; log "fill_s=$(( $(date +%s)-s ))"
s=$(date +%s); $P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_idx ON docs USING fts (d)" >/dev/null; log "build_s=$(( $(date +%s)-s )) size=$($P -c "select pg_relation_size('docs_idx')")"
r() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT 10) s;"; }
r slovakia > /tmp/q_rare.sql; r hungary > /tmp/q_mid.sql; r year > /tmp/q_common.sql
echo "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year');" > /tmp/q_count.sql
pgb() { PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off ${PGX:-}" $B/pgbench -h /tmp -U postgres -n -f /tmp/q_$1.sql -c $2 -j ${3:-$(( $2 < 8 ? $2 : 8 ))} -T ${4:-30} postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p'; }
# 2. unsettled probe: straight after the build
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
pgb rare 8 8 10 >/dev/null
log "unsettled rare c16: $(pgb rare 16) $(pgb rare 16)"
# 3. settled, twice (tps2.sh, identical to the release run)
for rr in 1 2; do bash /tmp/tps2_110.sh fts $OUT/tps_settled_r$rr.txt >/dev/null 2>&1
  log "settled r$rr: $(grep pass= $OUT/tps_settled_r$rr.txt | sed 's/ c32=[0-9.]*//; s/\.[0-9]*//g' | tr '\n' ' ')"; done
# 4. single-client latency (protocol form) + c1 tps
for q in rare common; do
  sql=$(sed 's/;$//' /tmp/q_$q.sql); meds=""
  for pass in 1 2 3; do
    { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
    meds="$meds $($P -f /tmp/b.sql 2>&1 | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | tail -5 | sort -n | sed -n 3p)"
  done
  log "latency $q k10 pass medians:$meds  c1 tps=$(pgb $q 1 1 20)"
done
# 5. at c16: vmstat, wait events, perf stat, perf record (c16 and c1)
for q in rare common; do
  PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/q_$q.sql -c 16 -j 8 -T 40 postgres > $OUT/pgb_${q}_16.txt 2>&1 &
  PB=$!; sleep 5
  vmstat 1 10 > $OUT/vm_${q}_16.txt &
  for i in $(seq 1 200); do $P -c "SELECT coalesce(wait_event_type,'CPU')||':'||coalesce(wait_event,'-') FROM pg_stat_activity WHERE backend_type='client backend' AND state='active' AND pid<>pg_backend_pid()" ; sleep 0.05; done > $OUT/wait_${q}_16.raw
  sudo perf stat -a -e cycles,instructions,cache-misses,LLC-load-misses,stalled-cycles-backend -- sleep 5 > $OUT/perfstat_${q}_16.txt 2>&1
  sudo perf record -a -g -F 499 -o /nvme/perf_${q}_16.data -- sleep 8 >/dev/null 2>&1
  wait $PB
  log "c16 $q: tps=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' $OUT/pgb_${q}_16.txt) vmstat(us sy id cs)=$(awk 'NR>3{us+=$13;sy+=$14;id+=$15;cs+=$12;n++} END{printf "%.0f %.0f %.0f %.0f", us/n,sy/n,id/n,cs/n}' $OUT/vm_${q}_16.txt) waits=$(sort $OUT/wait_${q}_16.raw | uniq -c | sort -rn | head -4 | awk '{print $2"="$1}' | tr '\n' ' ')"
  sudo perf report -i /nvme/perf_${q}_16.data --no-children --sort dso,sym --stdio 2>/dev/null | grep -E '^ +[0-9]' | head -40 > $OUT/perf_${q}_16.txt
  # c1 profile for the per-transaction comparison
  PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/q_$q.sql -c 1 -j 1 -T 20 postgres > $OUT/pgb_${q}_1.txt 2>&1 &
  PB=$!; sleep 4
  sudo perf record -a -g -F 499 -o /nvme/perf_${q}_1.data -- sleep 8 >/dev/null 2>&1
  wait $PB
  sudo perf report -i /nvme/perf_${q}_1.data --no-children --sort dso,sym --stdio 2>/dev/null | grep -E '^ +[0-9]' | head -40 > $OUT/perf_${q}_1.txt
  log "c1 $q: tps=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' $OUT/pgb_${q}_1.txt)"
done
# 6. shared_doclen off vs on, alternating, rare + common c16 (PGC_SUSET: pgbench connects as postgres)
for rep in 1 2; do for sd in on off; do
  log "shared_doclen=$sd rep=$rep: rare c16=$(PGX="-c pg_fts.shared_doclen=$sd" pgb rare 16) common c16=$(PGX="-c pg_fts.shared_doclen=$sd" pgb common 16)"
done; done
# 7. pgbench threads: -j 16 vs -j 8
log "rare c16 -j8=$(pgb rare 16 8) -j16=$(pgb rare 16 16) -j8=$(pgb rare 16 8) -j16=$(pgb rare 16 16)"
log TV_DONE
