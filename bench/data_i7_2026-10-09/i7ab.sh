#!/bin/bash
# I7 A/B (bench/PLAN_I7_2026-10-09.md) on one host.  Arms: rel (1.11.0 PGXN zip), i7.
# Same data directory and index (built by rel); alternating; mbench2 before and after to
# record the host state.  Expects comp_setup111.sh fts done and /tmp/fts_i7.tgz.
set -uo pipefail
OUT=/nvme/i7; mkdir -p $OUT
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir)
P="$B/psql -h /tmp -U postgres -X -q -At"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
cd /nvme; tar xzf /tmp/fts_i7.tgz; (cd fts_i7 && make -s PG_CONFIG=$B/pg_config -j16 >/nvme/ext_build_i7.log 2>&1) ; cp fts_i7/pg_fts.so /nvme/pg_fts_i7.so
log "so rel=$(md5sum /nvme/pg_fts_rel.so | cut -c1-8) i7=$(md5sum /nvme/pg_fts_i7.so | cut -c1-8) i7_commit=$(cat /tmp/fts_i7.commit) marker=$(strings /nvme/pg_fts_i7.so | grep -c 'pg_fts dict directory') build_warnings=$(grep -c warning /nvme/ext_build_i7.log)"
cc -O2 /tmp/mbench2.c -o /tmp/mbench2; log "mbench2 before: $(/tmp/mbench2 | grep '1024 MiB 4k\|4096 MiB 4k' | sed 's/ (AnonHuge.*//' | tr '\n' ' ')"
use() { $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$1.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
        $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null; }
cp /nvme/pg_fts_rel.so $LIB/pg_fts.so
bash /tmp/cluster3.sh fts > $OUT/cluster.log 2>&1
$P -c "CREATE EXTENSION pg_fts" -c "CREATE EXTENSION pg_prewarm" >/dev/null
$P -c "ALTER TABLE docs ADD COLUMN d ftsdoc" -c "UPDATE docs SET d = to_ftsdoc('english', content)" -c "VACUUM (FREEZE, ANALYZE) docs" >/dev/null
$P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_idx ON docs USING fts (d)" >/dev/null
s=$(date +%s); $P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_pos ON docs USING fts (d) WITH (positions = on)" >/dev/null
log "indexes: docs_idx=$($P -c "select pg_relation_size('docs_idx')") docs_pos=$($P -c "select pg_relation_size('docs_pos')")"
r() { echo "SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2"; }
hide() { echo "BEGIN; UPDATE pg_index SET indisvalid = false WHERE indexrelid = '$1'::regclass;"; }
BANDS=("rare_k10;docs_pos;slovakia;10" "mid_k10;docs_pos;hungary;10" "common_k10;docs_pos;year;10" "common_k100;docs_pos;year;100"
       "and_k10;docs_pos;slovakia & hungary;10" "or_k10;docs_pos;slovakia | hungary;10"
       "and_common_k10;docs_pos;united & states;10" "and_ww_k10;docs_pos;world & war;10"
       "or4_k10;docs_pos;film | music | album | band;10"
       "phrase_k10;docs_idx;\"united states\";10" "phrase_ww_k10;docs_idx;\"world war\";10")
# --- correctness gate: ids + index scores identical, both arms, every band; also buffers ---
for arm in rel i7; do use $arm
  for bq in "${BANDS[@]}"; do IFS=';' read n hx q k <<< "$bq"
    ix=$([ $hx = docs_pos ] && echo docs_idx || echo docs_pos)
    { hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"
      echo "SELECT string_agg(id::text, ',') FROM ($(r "$q" $k)) s;"
      echo "SELECT string_agg(ctid::text || ':' || round(score::numeric, 9)::text, ',') FROM fts_search('$ix', to_ftsquery('english','$q'), $k);"
      echo "ROLLBACK;"; } > /tmp/g.sql
    $P -f /tmp/g.sql 2>&1 | grep -v -E '^(BEGIN|UPDATE|SET|ROLLBACK)' > $OUT/gate_${arm}_$n.txt
    { hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"
      for i in 1 2; do echo "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) $(r "$q" $k);"; done; echo "ROLLBACK;"; } > /tmp/e.sql
    echo "$n $($P -f /tmp/e.sql 2>&1 | sed -n '/^Limit/,/^Planning/p' | grep 'Buffers' | sed -n 3p | grep -o 'hit=[0-9]*.*')" >> $OUT/buffers_$arm.txt
  done
  echo "count_common $($P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')")" > $OUT/gate_${arm}_count.txt
done
bad=0; for bq in "${BANDS[@]}" "count;x;x;x"; do n=${bq%%;*}
  cmp -s $OUT/gate_rel_$n.txt $OUT/gate_i7_$n.txt || { bad=$((bad+1)); log "GATE FAIL $n"; }
  [ -s $OUT/gate_i7_$n.txt ] && ! grep -q ERROR $OUT/gate_i7_$n.txt || { bad=$((bad+1)); log "GATE EMPTY/ERROR $n"; }
done
log "gate: $bad failures; buffers rel vs i7: $(paste -d' ' $OUT/buffers_rel.txt $OUT/buffers_i7.txt | awk '{print $1": "$2" -> "$4}' | tr '\n' ' ')"
[ $bad -eq 0 ] || { log "GATE FAILED: not timing"; exit 1; }
# --- latency: 3 passes per band per arm, alternating ---
for pass in 1 2 3; do for arm in rel i7; do use $arm; $P -c "SELECT pg_prewarm('docs_pos')" >/dev/null
  for bq in "${BANDS[@]}" "count_common;docs_pos;COUNT;0"; do IFS=';' read n hx q k <<< "$bq"
    if [ "$q" = COUNT ]; then sql="SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')"; else sql="SELECT count(*) FROM ($(r "$q" $k)) s"; fi
    { hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; echo "ROLLBACK;"; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | head -n 8 | tr '\n' ' ')
    echo "pass=$pass arm=$arm band=$n median_last5=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p) raw=[$ts]" >> $OUT/latency.txt
  done
done; done
log LAT_DONE
# --- throughput: c16 / c64, rare mid common count, alternating, 3 rounds, 20 s points ---
$P -c "DROP INDEX docs_pos" >/dev/null
q1() { echo "SELECT count(*) FROM ($(r "$1" 10)) s;"; }
q1 slovakia > /tmp/q_rare.sql; q1 hungary > /tmp/q_mid.sql; q1 year > /tmp/q_common.sql; q1 "united & states" > /tmp/q_and.sql
echo "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year');" > /tmp/q_count.sql
pgb() { PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/q_$1.sql -c $2 -j $(( $2 < 8 ? $2 : 8 )) -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | cut -d. -f1; }
for round in 1 2 3; do for arm in rel i7 i7 rel; do use $arm; pgb rare 8 >/dev/null
  log "round=$round arm=$arm rare c16=$(pgb rare 16) c64=$(pgb rare 64) mid c16=$(pgb mid 16) c64=$(pgb mid 64) common c16=$(pgb common 16) c64=$(pgb common 64) and c16=$(pgb and 16) count c16=$(pgb count 16)"
done; done
log "mbench2 after: $(/tmp/mbench2 | grep '1024 MiB 4k\|4096 MiB 4k' | sed 's/ (AnonHuge.*//' | tr '\n' ' ')"
log "server errors: $(grep -cE 'ERROR|PANIC|terminated by signal' $D/server.log)"
log I7AB_DONE
