#!/bin/bash
# 1.11.0 release benchmark, pg_fts host (bench/PROTOCOL_111_2026-10-09.md).  The Approach A
# harness (data_A_2026-10-07/run/fts_ab.sh) with arms rel (1.11.0 release from the PGXN zip)
# and a (39b6a42, the binary RESULTS_A measured).  Release builds first; measured indexes
# are the release-built ones; both arms read them.
# usage: fts_111.sh <outdir>      both .so in /nvme/pg_fts_rel.so and /nvme/pg_fts_a.so
set -uo pipefail
OUT=$1; mkdir -p $OUT
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir)
P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
use() {  # switch the installed binary and restart (same data, same index files)
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$1.so $LIB/pg_fts.so
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null; ARM=$1; }
log "host=<host> arch=$(uname -m) cpu=$(lscpu | sed -n 's/^Model name: *//p') nproc=$(nproc) pg=$($B/postgres --version)"
log "corpus md5=$(md5sum /nvme/c.tsv | cut -c1-32) rows=$($P -c 'select count(*) from docs')"
log "so rel=$(md5sum /nvme/pg_fts_rel.so | cut -c1-8) a=$(md5sum /nvme/pg_fts_a.so | cut -c1-8) zip_sha256=$(sha256sum /tmp/pg_fts-1.11.0.zip | cut -c1-16) a_tree=$(cat /tmp/fts_a.commit 2>/dev/null)"
log "markers rel: seal=$(grep -c 'Seal the list first' /nvme/pg_fts-1.11.0/pg_fts_am.c) prune=$(grep -c 'pd_prune_xid = ReadNextTransactionId' /nvme/pg_fts-1.11.0/pg_fts_am.c) | a: seal=$(grep -c 'Seal the list first' /nvme/fts_a/pg_fts_am.c)"
use rel
$P -c "CREATE EXTENSION IF NOT EXISTS pg_fts" -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm" -c "CREATE EXTENSION IF NOT EXISTS pg_buffercache" >/dev/null
log "ext $($P -c "SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"

# ---- builds ----  (SKIP_BUILDS=1: reuse the indexes of a previous run; run.log keeps their numbers)
if [ "${SKIP_BUILDS:-0}" != 1 ]; then
# (a) expression index on the raw table: analysis inside the build, like the other engines
for arm in rel a; do use $arm
  $P -c "DROP INDEX IF EXISTS docs_expr" >/dev/null
  s=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_expr ON docs USING fts (to_ftsdoc('english', content))"; e=$(date +%s.%N)
  sz=$($P -c "select pg_relation_size('docs_expr')")
  s2=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "SELECT fts_vacuum('docs_expr')" >/dev/null; e2=$(date +%s.%N)
  log "arm=$arm expr_build_s=$(echo "$e-$s"|bc) size_after_build=$sz fts_vacuum_s=$(echo "$e2-$s2"|bc) size=$($P -c "select pg_relation_size('docs_expr')")"
  $P -c "DROP INDEX docs_expr" >/dev/null
done
# (b) stored column (the fill is timed separately, once)
s=$(date +%s.%N); $P -c "ALTER TABLE docs ADD COLUMN d ftsdoc" -c "UPDATE docs SET d = to_ftsdoc('english', content)" -c "VACUUM (FREEZE, ANALYZE) docs" >/dev/null; log "column_fill_s=$(echo "$(date +%s.%N)-$s"|bc)"
for arm in rel a; do use $arm
  for pos in off on; do ix=docs_$( [ $pos = on ] && echo pos || echo idx )_$arm
    $P -c "DROP INDEX IF EXISTS $ix" >/dev/null
    s=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "CREATE INDEX $ix ON docs USING fts (d) WITH (positions = $pos)"; e=$(date +%s.%N)
    sz=$($P -c "select pg_relation_size('$ix')")
    s2=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "SELECT fts_vacuum('$ix')" >/dev/null; e2=$(date +%s.%N)
    log "arm=$arm positions=$pos column_build_s=$(echo "$e-$s"|bc) size_after_build=$sz fts_vacuum_s=$(echo "$e2-$s2"|bc) size=$($P -c "select pg_relation_size('$ix')")"
  done
done
$P -c "DROP INDEX docs_idx_a" -c "DROP INDEX docs_pos_a" >/dev/null
$P -c "ALTER INDEX docs_idx_rel RENAME TO docs_idx" -c "ALTER INDEX docs_pos_rel RENAME TO docs_pos" >/dev/null
log "measuring on docs_idx=$($P -c "select pg_relation_size('docs_idx')") docs_pos=$($P -c "select pg_relation_size('docs_pos')") (built by arm rel)"
fi
if [ "${SKIP_BUILDS:-0}" = 1 ] && [ -z "$($P -c "SELECT to_regclass('docs_pos')")" ]; then
  use rel; s=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_pos ON docs USING fts (d) WITH (positions = on)"
  log "restart: rebuilt docs_pos with arm rel in $(echo "$(date +%s.%N)-$s"|bc) s, size=$($P -c "select pg_relation_size('docs_pos')")"
fi
# ---- bands ------------------------------------------------------------------------
r() { echo "SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2"; }
BANDS=("rare_k10;docs_pos;slovakia;10" "mid_k10;docs_pos;hungary;10" "common_k10;docs_pos;year;10" "common_k100;docs_pos;year;100"
       "and_k10;docs_pos;slovakia & hungary;10" "or_k10;docs_pos;slovakia | hungary;10"
       "and_common_k10;docs_pos;united & states;10" "and_ww_k10;docs_pos;world & war;10"
       "or4_k10;docs_pos;film | music | album | band;10"
       "phrase_k10;docs_idx;\"united states\";10" "phrase_ww_k10;docs_idx;\"world war\";10")
hide() { echo "BEGIN; UPDATE pg_index SET indisvalid = false WHERE indexrelid = '$1'::regclass;"; }

# correctness gate: both arms return the same ids and (within 1e-9) the same index scores
for arm in rel a; do use $arm
  for bq in "${BANDS[@]}"; do IFS=';' read n hx q k <<< "$bq"
    ix=$([ $hx = docs_pos ] && echo docs_idx || echo docs_pos)
    { hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"
      echo "SELECT string_agg(id::text, ',') FROM ($(r "$q" $k)) s;"
      echo "SELECT string_agg(ctid::text || ':' || round(score::numeric, 9)::text, ',') FROM fts_search('$ix', to_ftsquery('english','$q'), $k);"
      echo "ROLLBACK;"; } > /tmp/g.sql
    $P -f /tmp/g.sql 2>&1 | grep -v -E '^(BEGIN|UPDATE|SET|ROLLBACK)' > $OUT/gate_${arm}_$n.txt
  done
  echo "count_common $($P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')")" > $OUT/gate_${arm}_count.txt
done
ok=0; bad=0; BADBANDS=""
for f in $OUT/gate_*.txt; do grep -q ERROR $f && { bad=$((bad+1)); log "GATE ERROR in $f"; }; done
for bq in "${BANDS[@]}" "count;x;x;x"; do n=${bq%%;*}
  if cmp -s $OUT/gate_rel_$n.txt $OUT/gate_a_$n.txt; then ok=$((ok+1)); else
    a=$(tail -n 1 $OUT/gate_rel_$n.txt | tr ',' '\n' | sed 's/.*://' | md5sum); b=$(tail -n 1 $OUT/gate_a_$n.txt | tr ',' '\n' | sed 's/.*://' | md5sum)
    [ "$a" = "$b" ] && { ok=$((ok+1)); log "gate $n: tie order differs, scores identical"; } || { bad=$((bad+1)); BADBANDS="$BADBANDS $n"; log "GATE FAIL $n"; }
  fi
done
for f in $OUT/gate_rel_*.txt; do [ -s $f ] && ! grep -q '^$' $f || { bad=$((bad+1)); log "GATE EMPTY $f"; }; done
log "gate: $ok bands identical, $bad differ"
# exhaustive references on the release arm (index docs_idx / docs_pos)
use rel
python3 /tmp/mt_oracle_idx.py "film | music | album | band" "slovakia | hungary" > $OUT/oracle_or.txt 2>&1
python3 /tmp/and_oracle_idx.py docs_idx 'united & states' 'slovakia & hungary' 'world & war' > $OUT/oracle_and.txt 2>&1
python3 /tmp/and_oracle_idx.py docs_pos '"united states"' '"world war"' > $OUT/oracle_phrase.txt 2>&1
log "oracle or: $(tail -n 1 $OUT/oracle_or.txt) | and: $(tail -n 1 $OUT/oracle_and.txt) | phrase: $(tail -n 1 $OUT/oracle_phrase.txt)"
for f in oracle_or oracle_and oracle_phrase; do grep -q "TOTAL.* 0 differ" $OUT/$f.txt || { bad=$((bad+1)); log "ORACLE FAIL $f"; }; done
[ $bad -eq 0 ] || { log "GATE FAILED ($BADBANDS): not timing"; exit 1; }

# warm latency: 3 passes per band per arm, alternating arms within each pass
for pass in 1 2 3; do for arm in rel a; do use $arm
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx'), pg_prewarm('docs_pos')" >/dev/null
  for bq in "${BANDS[@]}" "count_common;docs_pos;COUNT;0"; do IFS=';' read n hx q k <<< "$bq"
    if [ "$q" = COUNT ]; then sql="SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')"; else sql="SELECT count(*) FROM ($(r "$q" $k)) s"; fi
    { hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; echo "ROLLBACK;"; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | head -n 8 | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "pass=$pass arm=$arm band=$n rows=$(grep -v -E '^(Time|BEGIN|UPDATE|SET|ROLLBACK)' /tmp/b.out | sort -u | tr '\n' ',') median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
  done
done; done
log LAT_DONE

# cold band: autoprewarm off, drop caches, one query, 5 reps, median of EXPLAIN execution time
$P -c "ALTER SYSTEM SET pg_prewarm.autoprewarm = off" >/dev/null; rm -f $D/autoprewarm.blocks
for eic in 1 16; do $P -c "ALTER SYSTEM SET effective_io_concurrency = $eic" >/dev/null
  for arm in rel a; do
    for bq in "rare_k10;docs_pos;slovakia;10" "common_k10;docs_pos;year;10" "and_common_k10;docs_pos;united & states;10"; do IFS=';' read n hx q k <<< "$bq"
      vals=""
      for rep in 1 2 3 4 5; do
        use $arm; $B/pg_ctl -D $D -w stop >/dev/null 2>&1; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
        $P -c "SELECT to_ftsquery('english','x')" >/dev/null
        v=$({ hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"; echo "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $(r "$q" $k);"; echo "ROLLBACK;"; } | $P -f - 2>&1 | grep -v -E '^(BEGIN|UPDATE|SET|ROLLBACK)' | python3 -c "import json,sys; j=json.loads(sys.stdin.read())[0]; p=j['Plan']; print('%.2f/%d' % (j['Execution Time'], p.get('Shared Read Blocks',0)))")
        vals="$vals $v"
      done
      med=$(echo $vals | tr ' ' '\n' | sort -t/ -k1 -n | sed -n 3p)
      echo "eic=$eic arm=$arm band=$n cold_median_ms/reads=$med all=[$vals]" | tee -a $OUT/cold.txt
    done
  done
done
$P -c "ALTER SYSTEM RESET effective_io_concurrency" -c "ALTER SYSTEM RESET pg_prewarm.autoprewarm" >/dev/null
use rel
log COLD_DONE

# throughput (in-run form) on the non-positional index, both arms
$P -c "DROP INDEX docs_pos" >/dev/null
for arm in rel a; do use $arm
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  $P -c "CHECKPOINT" >/dev/null; sync; sleep 60
  for bq in "rare_k10;slovakia;10" "mid_k10;hungary;10" "common_k10;year;10" "and_common_k10;united & states;10" "count_common;COUNT;0"; do IFS=';' read n q k <<< "$bq"
    if [ "$q" = COUNT ]; then echo "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year');" > /tmp/w_$n.sql; else echo "SELECT count(*) FROM ($(r "$q" $k)) s;" > /tmp/w_$n.sql; fi
    PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/w_$n.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
    for pass in 1 2; do line="arm=$arm pass=$pass band=$n"
      for c in 16 32 64; do j=$(( c < 8 ? c : 8 ))
        line="$line c$c=$(PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/w_$n.sql -c $c -j $j -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"
      done; echo "$line" | tee -a $OUT/tps.txt
    done
  done
done
log TPS_INRUN_DONE

# settled throughput (tps2.sh), order rel, a, a, rel
for arm_sfx in "rel 1" "a 1" "a 2" "rel 2"; do set -- $arm_sfx; use $1
  bash /tmp/tps2_110.sh fts $OUT/tps_settled_$1_r$2.txt > /dev/null 2>&1
  log "settled arm=$1 run=$2: $(grep -c pass= $OUT/tps_settled_$1_r$2.txt) lines"
done
use rel
log TPS_SETTLED_DONE

# concurrent-write band (release only): 8 single-row inserters + 4 rare-k10 readers, 120 s,
# fts_merge every 30 s; afterwards index count must equal heap count for the inserted term
$P -c "CREATE TABLE w (id bigserial PRIMARY KEY, d ftsdoc)" -c "INSERT INTO w(d) SELECT to_ftsdoc('english', content) FROM docs WHERE id % 20 = 0" -c "CREATE INDEX w_fts ON w USING fts (d)" -c "VACUUM ANALYZE w" >/dev/null
echo "INSERT INTO w(d) VALUES (to_ftsdoc('english', 'writeprobe slovakia ' || md5(random()::text)));" > /tmp/w_ins.sql
echo "SELECT count(*) FROM (SELECT id FROM w WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;" > /tmp/w_read.sql
$B/pgbench -h /tmp -U postgres -n -f /tmp/w_ins.sql -c 8 -j 8 -T 120 postgres > $OUT/write_ins.txt 2>&1 &
IP=$!
PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/w_read.sql -c 4 -j 4 -T 120 postgres > $OUT/write_read.txt 2>&1 &
RP=$!
for i in 1 2 3; do sleep 30; $P -c "SELECT fts_merge('w_fts')" >/dev/null 2>>$OUT/write_maint.err; done
wait $IP $RP
heap=$($P -c "SELECT count(*) FROM w WHERE fts_match(d, to_ftsquery('english','writeprobe'))")
idx=$($P -c "SET enable_seqscan=off; SELECT count(*) FROM w WHERE d @@@ to_ftsquery('english','writeprobe')")
log "write band: ins $(grep -E '^tps|failed' $OUT/write_ins.txt | tr '\n' ' ') | read $(grep -E '^tps|failed' $OUT/write_read.txt | tr '\n' ' ') | heap=$heap index=$idx maint_err=$(wc -l < $OUT/write_maint.err) server_errors=$(grep -cE 'ERROR|terminated by signal' $D/server.log)"
log ALL_DONE
