#!/bin/bash
# pg_fts 1.13.0 vs pg_textsearch on EC2 metal, Fedora, XFS on local NVMe.
# bench/PROTOCOL_PGTS_METAL_2026-10-15.md.  One host runs every arm; arms alternate per
# pass; each arm has its own copy of the docs table (so a planner never chooses between
# two engines' indexes on one table).
#   phases: setup | build | lat | tps | cold | write | agree | all
set -uo pipefail
PH=${1:-all}
OUT=/nvme/out; mkdir -p $OUT
B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a $OUT/run.log; }
ARMS="fts pgts_head pgts_rel"     # pg_fts 1.13.0, pg_textsearch a5fdfeb1, pg_textsearch v1.5.1
hoststate() {
  log "hoststate $1: $(/nvme/mbench2 2>&1 | tail -1) | load $(cut -d' ' -f1-3 /proc/loadavg) | thp $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
}

setup() {
  exec >> $OUT/setup.log 2>&1
  log "host $(uname -m) $(uname -r) $(lscpu | sed -n 's/^Model name: *//p' | head -1) nproc=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G"
  log "os $(. /etc/os-release; echo $PRETTY_NAME)"
  numactl -H 2>/dev/null | head -3 >> $OUT/run.log
  gcc -O2 -o /nvme/mbench2 /tmp/mbench2.c && hoststate start
  cd /nvme
  # PostgreSQL 17.10, same flags everywhere
  curl -sfLO https://ftp.postgresql.org/pub/source/v17.10/postgresql-17.10.tar.bz2
  tar xjf postgresql-17.10.tar.bz2; cd postgresql-17.10
  ./configure --prefix=/nvme/pg17 CFLAGS="-O2 -g -fno-omit-frame-pointer" > /nvme/cfg.log 2>&1
  make -s -j$(nproc) > /nvme/mk.log 2>&1 || { log PG_BUILD_FAILED; tail -20 /nvme/mk.log; exit 1; }; make -s install > /dev/null
  for c in pg_prewarm pg_buffercache; do (cd contrib/$c && make -s install > /dev/null); done
  log "pg $($B/postgres --version)"
  # engines: one PostgreSQL prefix per arm (pg_textsearch checks that the loaded library
  # matches its installed SQL version, so its two arms cannot share a prefix); the three
  # prefixes are copies of ONE build, so the server binary is identical.
  for a in fts pgts_head pgts_rel; do [ -d /nvme/pg_$a ] || cp -a /nvme/pg17 /nvme/pg_$a; done
  cd /nvme; mkdir -p src_pgts_rel src_pgts_head
  tar xzf /tmp/pgts_v151.tgz -C src_pgts_rel; tar xzf /tmp/pgts_head.tgz -C src_pgts_head
  for a in pgts_rel pgts_head; do (cd /nvme/src_$a && make -s PG_CONFIG=/nvme/pg_$a/bin/pg_config -j$(nproc) > /nvme/$a.mk.log 2>&1 && make -s PG_CONFIG=/nvme/pg_$a/bin/pg_config install > /dev/null 2>&1); done
  log "pgts_rel $(cat /nvme/src_pgts_rel/GITREV) so=$(md5sum /nvme/pg_pgts_rel/lib/postgresql/pg_textsearch.so | cut -c1-8)  pgts_head $(cat /nvme/src_pgts_head/GITREV) so=$(md5sum /nvme/pg_pgts_head/lib/postgresql/pg_textsearch.so | cut -c1-8)"
  echo "47e24fd4cc66acced9f55e0d212cba2fe3e6b2865f065e334970df03c5b7be55  /tmp/pg_fts-1.13.0.zip" | sha256sum -c - || { log "PG_FTS ZIP SHA MISMATCH"; exit 1; }
  unzip -qo /tmp/pg_fts-1.13.0.zip -d /nvme; (cd /nvme/pg_fts-1.13.0 && make -s PG_CONFIG=/nvme/pg_fts/bin/pg_config -j$(nproc) > /nvme/fts.mk.log 2>&1 && make -s PG_CONFIG=/nvme/pg_fts/bin/pg_config install > /dev/null)
  log "pg_fts so=$(md5sum /nvme/pg_fts/lib/postgresql/pg_fts.so | cut -c1-8) postgres binaries identical: $(md5sum /nvme/pg_fts/bin/postgres /nvme/pg_pgts_head/bin/postgres /nvme/pg_pgts_rel/bin/postgres | cut -c1-32 | sort -u | wc -l)"
  # corpus (pinned HF dataset), md5 must match
  python3 -m venv /nvme/venv; /nvme/venv/bin/pip -q install pyarrow huggingface_hub
  cat > /nvme/corpus.py <<'PY'
import sys, os, pyarrow.parquet as pq
from huggingface_hub import list_repo_files, hf_hub_download
REPO="wikimedia/wikipedia"; CONFIG="20231101.en"; N=int(os.environ.get("CORPUS_N") or "2188038")
files=sorted(f for f in list_repo_files(REPO, repo_type="dataset") if f.startswith(CONFIG+"/") and f.endswith(".parquet"))
out=open("/nvme/c.tsv","w",encoding="utf-8"); n=0
for f in files:
    p=hf_hub_download(REPO, f, repo_type="dataset", cache_dir="/nvme/hf")
    t=pq.read_table(p, columns=["id","title","text"])
    for i,ti,b in zip(t.column("id").to_pylist(), t.column("title").to_pylist(), t.column("text").to_pylist()):
        c=((ti or "")+" "+(b or "")).replace("\t"," ").replace("\n"," ").replace("\r"," ").replace("\\"," ")
        out.write(f"{i}\t{c}\n"); n+=1
        if n==N: break
    os.remove(os.path.realpath(p))
    if n==N: break
out.close(); print("ROWS", n)
PY
  CORPUS_N=${CORPUS_N:-} /nvme/venv/bin/python3 /nvme/corpus.py
  m=$(md5sum /nvme/c.tsv | cut -c1-32); log "corpus md5=$m rows=$(wc -l < /nvme/c.tsv)"
  if [ -z "${CORPUS_N:-}" ]; then case $m in f5939e85*) ;; *) log "CORPUS MD5 MISMATCH"; exit 1 ;; esac; else log "SMOKE corpus N=$CORPUS_N (md5 not checked)"; fi
  clusters
  log SETUP_DONE
}
clusters() {
  # clusters: identical settings; each preloads only what its arm needs
  for a in fts pgts_head pgts_rel; do
    D=/nvme/data_$a; BB=/nvme/pg_$a/bin; $BB/initdb -D $D -U postgres --no-locale -E UTF8 > /dev/null
    PRE=pg_prewarm; [ $a != fts ] && PRE="pg_prewarm,pg_textsearch"
    cat >> $D/postgresql.conf <<C
listen_addresses=''
unix_socket_directories='/tmp'
max_connections=300
shared_buffers=${SB:-32GB}
maintenance_work_mem=${MWM:-8GB}
work_mem=256MB
jit=off
autovacuum=off
max_wal_size=64GB
max_parallel_maintenance_workers=8
max_parallel_workers=32
max_worker_processes=32
shared_preload_libraries='$PRE'
pg_prewarm.autoprewarm=off
default_text_search_config='english'
C
    $BB/pg_ctl -D $D -l $D/server.log -w start > /dev/null || { log "CLUSTER $a FAILED TO START"; tail -3 $D/server.log; exit 1; }
    $BB/psql -h /tmp -U postgres -X -q -c "CREATE TABLE docs(id bigint PRIMARY KEY, content text)" -c "\\copy docs FROM '/nvme/c.tsv' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\b')" -c "VACUUM (FREEZE, ANALYZE) docs" -c "CREATE EXTENSION pg_prewarm" -c "CREATE EXTENSION pg_buffercache"
    if [ $a = fts ]; then $BB/psql -h /tmp -U postgres -X -q -c "CREATE EXTENSION pg_fts"; else $BB/psql -h /tmp -U postgres -X -q -c "CREATE EXTENSION pg_textsearch"; fi
    log "cluster $a rows=$($BB/psql -h /tmp -U postgres -X -At -c 'select count(*) from docs') ext=$($BB/psql -h /tmp -U postgres -X -At -c "select string_agg(extname||' '||extversion, ',') from pg_extension where extname in ('pg_fts','pg_textsearch')")"
    $BB/pg_ctl -D $D -w stop > /dev/null
  done
}

# one cluster runs at a time; arm X uses prefix /nvme/pg_X and data /nvme/data_X
CUR=""
arm() {
  [ "$CUR" = "$1" ] && return
  for x in fts pgts_head pgts_rel; do /nvme/pg_$x/bin/pg_ctl -D /nvme/data_$x -w stop -m fast > /dev/null 2>&1; done
  B=/nvme/pg_$1/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
  $B/pg_ctl -D /nvme/data_$1 -l /nvme/data_$1/server.log -w start > /dev/null || { log "ARM $1 FAILED TO START"; exit 1; }; CUR=$1
}
# every relation in the database other than the heap, its toast and pkey: what each
# engine's index costs on disk
rels() { $P -c "select coalesce(sum(pg_relation_size(c.oid)),0) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname not in ('pg_catalog','information_schema','pg_toast') and c.relkind in ('i','r','t','m') and c.relname not in ('docs','docs_pkey','docs_pos','docs_pos_pkey','fts_pos')"; }
build() {
  # pg_textsearch: each arm builds its own index with its own .so
  for a in pgts_rel pgts_head; do
    arm $a
    v=$($P -c "SELECT extversion FROM pg_extension WHERE extname='pg_textsearch'")
    s=$(date +%s.%N)
    $P -c "CREATE INDEX docs_idx ON docs USING bm25(content) WITH (text_config='english')" 2>&1 | grep -v "too long" | tail -2
    log "build $a ext=$v s=$(echo "$(date +%s.%N)-$s" | bc) size=$($P -c "select pg_relation_size('docs_idx')") all_rels_bytes=$(rels)"
  done
  arm fts
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_idx ON docs USING fts (to_ftsdoc('english', content))"
  log "build fts expr s=$(echo "$(date +%s.%N)-$s" | bc) size=$($P -c "select pg_relation_size('docs_idx')")"
  s=$(date +%s.%N); $P -c "SELECT fts_vacuum('docs_idx')" > /dev/null; log "fts_vacuum s=$(echo "$(date +%s.%N)-$s" | bc) size=$($P -c "select pg_relation_size('docs_idx')")"
  # the positions = on index lives on its own copy of the table (docs_pos), so the planner
  # cannot pick it for a non-phrase band (it did, in the smoke test, once both indexes sat
  # on one table); phrase bands query docs_pos
  $P -c "CREATE TABLE docs_pos (id bigint PRIMARY KEY, content text)" -c "INSERT INTO docs_pos SELECT * FROM docs" -c "VACUUM (FREEZE, ANALYZE) docs_pos"
  s=$(date +%s.%N); $P -c "CREATE INDEX fts_pos ON docs_pos USING fts (to_ftsdoc('english', content)) WITH (positions = on)"
  log "build fts positions s=$(echo "$(date +%s.%N)-$s" | bc) size=$($P -c "select pg_relation_size('fts_pos')") all_rels_bytes_excl_docs_pos=$(rels)"
  for a in pgts_head pgts_rel fts; do arm $a; $P -c "VACUUM ANALYZE docs"; done
  log BUILD_DONE
}

# band SQL per arm.  pg_fts: docs carries the default index (docs_idx); docs_pos, a copy
# of the table, carries the positions = on index (fts_pos) used by the phrase bands.
fq() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','$1') ORDER BY to_ftsdoc('english', content) <=> to_ftsquery('english','$1') LIMIT $2) s"; }
tq() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$1','docs_idx') LIMIT $2) s"; }
tb() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE content @@ to_tsquery('english','$1') ORDER BY content <@> to_bm25query('$2','docs_idx') LIMIT $3) s"; }
tc() { echo "SELECT count(*) FROM (WITH f AS MATERIALIZED (SELECT id, content FROM docs WHERE content @@ to_tsquery('english','$1')) SELECT id FROM f ORDER BY content <@> to_bm25query('$2','docs_idx') LIMIT $3) s"; }
bands() {   # name|sql for arm $1
  local a=$1
  if [ $a = fts ]; then
    echo "rare_k10|$(fq slovakia 10)"; echo "mid_k10|$(fq hungary 10)"
    echo "common_k10|$(fq year 10)"; echo "common_k100|$(fq year 100)"; echo "common_k1000|$(fq year 1000)"
    echo "or2_k10|$(fq 'slovakia | hungary' 10)"; echo "or4_k10|$(fq 'film | music | album | band' 10)"
    echo "and_k10|$(fq 'slovakia & hungary' 10)"; echo "and_us_k10|$(fq 'united & states' 10)"
    echo "not_k10|$(fq 'hungary & !slovakia' 10)"
    echo "phrase_us_k10|$(fq '"united states"' 10 | sed 's/FROM docs WHERE/FROM docs_pos WHERE/')"; echo "phrase_ww_k10|$(fq '"world war"' 10 | sed 's/FROM docs WHERE/FROM docs_pos WHERE/')"
    echo "count_common|SELECT count(*) FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','year')"
  else
    echo "rare_k10|$(tq slovakia 10 $a)"; echo "mid_k10|$(tq hungary 10 $a)"
    echo "common_k10|$(tq year 10 $a)"; echo "common_k100|$(tq year 100 $a)"; echo "common_k1000|$(tq year 1000 $a)"
    echo "or2_k10|$(tq 'slovakia hungary' 10 $a)"; echo "or4_k10|$(tq 'film music album band' 10 $a)"
    echo "and_k10|$(tb 'slovakia & hungary' 'slovakia hungary' 10 $a)"; echo "and_us_k10|$(tb 'united & states' 'united states' 10 $a)"
    echo "not_k10|$(tb 'hungary & !slovakia' 'hungary' 10 $a)"
    echo "phrase_us_k10|$(tb 'united <-> states' 'united states' 10 $a)"; echo "phrase_ww_k10|$(tb 'world <-> war' 'world war' 10 $a)"
    # the same filtered bands in the fastest form found for pg_textsearch (protocol
    # amendment 1): filter through the index in a MATERIALIZED CTE, then score + sort
    echo "and_k10_cte|$(tc 'slovakia & hungary' 'slovakia hungary' 10)"; echo "and_us_k10_cte|$(tc 'united & states' 'united states' 10)"
    echo "not_k10_cte|$(tc 'hungary & !slovakia' 'hungary' 10)"
    echo "phrase_us_k10_cte|$(tc 'united <-> states' 'united states' 10)"; echo "phrase_ww_k10_cte|$(tc 'world <-> war' 'world war' 10)"
    echo "count_common|SELECT count(*) FROM docs WHERE content @@ to_tsquery('english','year')"
  fi
}
runsql() {   # $1 sql, stdout: psql output
  local sql=$1 pre="SET statement_timeout = '${STMT_TIMEOUT:-300s}';"
  local post=""
  { echo "$pre"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; echo "$post"; } > /tmp/b.sql
  $P -f /tmp/b.sql 2>&1
}
prewarm() { for t in docs docs_pos; do $P -c "SELECT 1 FROM pg_class WHERE relname='$t'" | grep -q 1 || continue; $P -c "SELECT pg_prewarm('$t')" > /dev/null; for i in $($P -c "select indexrelid::regclass from pg_index where indrelid='$t'::regclass"); do $P -c "SELECT pg_prewarm('$i')" > /dev/null; done; done; }
lat() {
  hoststate lat_start
  if [ -z "${RESUME:-}" ]; then
    for a in $ARMS; do arm $a; prewarm
      bands $a | while IFS='|' read -r n sql; do { echo "== $a $n"; $P -c "EXPLAIN $sql"; } >> $OUT/explain.txt 2>&1; done
    done
  fi
  for pass in $(seq 1 ${LAT_PASSES:-3}); do
    # rotate arm order per pass so no arm always runs first
    case $pass in 1) ord="fts pgts_head pgts_rel" ;; 2) ord="pgts_head pgts_rel fts" ;; 3) ord="pgts_rel fts pgts_head" ;; esac
    for a in $ord; do arm $a; prewarm
      bands $a | while IFS='|' read -r n sql; do
        grep -q "^pass=$pass arm=$a band=$n " $OUT/latency.txt 2>/dev/null && continue    # resume: already measured
        grep -qx "$n" /tmp/timedout_$a 2>/dev/null && { echo "pass=$pass arm=$a band=$n rows=TIMEOUT(300s) median_last5= raw=[skipped: timed out in an earlier pass]" | tee -a $OUT/latency.txt; continue; }
        # one probe execution; a band slower than 10 s is repeated 3 times (median of 3)
        # instead of 8 (median of the last 5): protocol amendment 6
        { echo "SET statement_timeout = '${STMT_TIMEOUT:-300s}';"; echo '\timing on'; echo "$sql;"; } > /tmp/p1.sql
        o=$($P -f /tmp/p1.sql 2>&1); t1=$(echo "$o" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | head -1)
        if echo "$o" | grep -q "statement timeout"; then
          echo "pass=$pass arm=$a band=$n rows=TIMEOUT(300s) median_last5= raw=[$t1]" | tee -a $OUT/latency.txt; echo "$n" >> /tmp/timedout_$a; continue; fi
        reps=8; awk -v t="${t1:-0}" 'BEGIN{exit !(t > 10000)}' && reps=3
        if awk -v t="${t1:-0}" 'BEGIN{exit !(t > 60000)}'; then
          # amendment 7: a band over 60 s is recorded from its probe (1 execution per pass)
          rows=$(echo "$o" | grep -vE '^Time:|^SET|^$|NOTICE|DETAIL' | sort -u | tr '\n' ',')
          echo "pass=$pass arm=$a band=$n rows=$rows median_last5=$t1 raw=[$t1] reps=1 probe=$t1" | tee -a $OUT/latency.txt; continue
        fi
        { echo "SET statement_timeout = '${STMT_TIMEOUT:-300s}';"; echo '\timing on'; for i in $(seq 1 $reps); do echo "$sql;"; done; } > /tmp/b.sql
        o=$($P -f /tmp/b.sql 2>&1)
        rows=$(echo "$o" | grep -vE '^Time:|^SET|^$' | sort -u | tr '\n' ',')
        ts=$(echo "$o" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | head -$reps | tr '\n' ' ')
        if [ $reps = 8 ]; then med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p); else med=$(echo "$ts" | tr ' ' '\n' | grep . | sort -n | sed -n 2p); fi
        echo "pass=$pass arm=$a band=$n rows=$rows median_last5=$med raw=[$ts] reps=$reps probe=$t1" | tee -a $OUT/latency.txt
      done
    done
  done
  hoststate lat_end; log LAT_DONE
}
tps() {
  hoststate tps_start
  for a in $ARMS; do arm $a; bands $a | while IFS='|' read -r n sql; do
      case $n in rare_k10|common_k10|and_us_k10|count_common) ;; *) continue ;; esac
      echo "${sql#POS:};" > /tmp/t_${a}_$n.sql; done; done
  for pass in 1 2; do
    case $pass in 1) ord="fts pgts_head pgts_rel" ;; 2) ord="pgts_rel pgts_head fts" ;; esac
    for a in $ord; do arm $a
      $P -c "CHECKPOINT" > /dev/null; sync; sleep ${SETTLE:-60}
      prewarm
      for f in /tmp/t_${a}_*.sql; do n=$(basename $f .sql); n=${n#t_${a}_}
        grep -qx "$n" /tmp/timedout_$a 2>/dev/null && { echo "pass=$pass arm=$a band=$n SKIPPED(timeout in latency)" | tee -a $OUT/tps.txt; continue; }
        lm=$(grep "^pass=1 arm=$a band=$n " $OUT/latency.txt | grep -o 'median_last5=[0-9.]*' | cut -d= -f2)
        awk -v t="${lm:-0}" 'BEGIN{exit !(t > 1000)}' && { echo "pass=$pass arm=$a band=$n SKIPPED(latency ${lm} ms > 1 s)" | tee -a $OUT/tps.txt; continue; }
        $B/pgbench -h /tmp -U postgres -n -f $f -c 8 -j 8 -T ${WARM:-10} postgres > /dev/null 2>&1
        line="pass=$pass arm=$a band=$n"
        for c in ${CLIENTS:-1 16 64 128 256}; do j=$(( c < 64 ? c : 64 ))
          line="$line c$c=$($B/pgbench -h /tmp -U postgres -n -f $f -c $c -j $j -T ${TPS_T:-30} postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"
        done; echo "$line" | tee -a $OUT/tps.txt
      done
    done
  done
  hoststate tps_end; log TPS_DONE
}
cold() {
  for rep in $(seq 1 ${COLD_REPS:-5}); do for a in $ARMS; do
    bands $a | while IFS='|' read -r n sql; do
      case $n in rare_k10|common_k10|and_k10|and_k10_cte) ;; *) continue ;; esac
      grep -qx "$n" /tmp/timedout_$a 2>/dev/null && { echo "rep=$rep arm=$a band=$n cold_ms=SKIPPED(timeout in latency)" | tee -a $OUT/cold.txt; continue; }
      arm $a; $B/pg_ctl -D /nvme/data_$a -w stop -m fast > /dev/null; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
      $B/pg_ctl -D /nvme/data_$a -l /nvme/data_$a/server.log -w start > /dev/null
      t=$($P -c "SET statement_timeout = '300s'" -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${sql#POS:}" 2>&1 | python3 -c "import json,sys
try: print(json.load(sys.stdin)[0]['Execution Time'])
except Exception as e: print('ERR', e)")
      echo "rep=$rep arm=$a band=$n cold_ms=$t" | tee -a $OUT/cold.txt
    done; done; done
  log COLD_DONE
}
write() {
  # 8 inserters (single-row autocommit, a unique token per row) + 8 readers (rare k10), 120 s
  for a in $ARMS; do arm $a
    $P -c "CREATE SEQUENCE IF NOT EXISTS wseq START 100000000000"
    cat > /tmp/w_ins_$a.sql <<SQL
INSERT INTO docs(id, content) VALUES (nextval('wseq'), 'zzwritetoken slovakia ' || nextval('wseq')::text);
SQL
    bands $a | grep "^rare_k10|" | cut -d'|' -f2- > /tmp/w_q_$a.sql
    # each arm starts from its own pre-run state: delete any earlier write-band rows
    $P -c "DELETE FROM docs WHERE content LIKE 'zzwritetoken%'" > /dev/null
    [ $a = fts ] && $P -c "VACUUM docs" -c "SELECT fts_merge('docs_idx')" > /dev/null
    [ $a != fts ] && $P -c "VACUUM docs" > /dev/null
    n0=$($P -c "select count(*) from docs where content like 'zzwritetoken%'")
    ( [ $a = fts ] && for i in 1 2 3 4; do sleep $(( ${WRITE_T:-120} / 4 )); $P -c "SELECT fts_merge('docs_idx')" > /dev/null 2>&1; done ) &
    MP=$!
    $B/pgbench -h /tmp -U postgres -n -f /tmp/w_ins_$a.sql -c 8 -j 8 -T ${WRITE_T:-120} postgres > /tmp/w_ins_$a.out 2>&1 &
    IP=$!
    $B/pgbench -h /tmp -U postgres -n -f /tmp/w_q_$a.sql -c 8 -j 8 -T ${WRITE_T:-120} postgres > /tmp/w_q_$a.out 2>&1
    wait $IP; wait $MP 2>/dev/null
    heap=$(( $($P -c "select count(*) from docs where content like 'zzwritetoken%'") - n0 ))
    if [ $a = fts ]; then idx=$($P -c "SET enable_seqscan=off" -c "SELECT count(*) FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','zzwritetoken')" | tail -1)
    else idx=$($P -c "SET enable_seqscan=off" -c "SELECT count(*) FROM (SELECT id, content FROM docs ORDER BY content <@> to_bm25query('zzwritetoken','docs_idx') LIMIT 100000000) s WHERE content like 'zzwritetoken%'" | tail -1); fi
    grep -q "aborted\|ERROR" /tmp/w_ins_$a.out && { log "WRITE BAND $a: inserts errored"; grep -m3 ERROR /tmp/w_ins_$a.out | tee -a $OUT/run.log; }
    echo "arm=$a insert_tps=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' /tmp/w_ins_$a.out) failed_ins=$(sed -n 's/^number of failed transactions: \([0-9]*\).*/\1/p' /tmp/w_ins_$a.out) query_tps=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' /tmp/w_q_$a.out) inserted_heap=$heap found_by_index=$idx" | tee -a $OUT/write.txt
  done
  log WRITE_DONE
}
agree() {
  # top-10 / top-100 ids per engine for single-term and OR bands, and every list rescored
  # with ONE formula (fts_bm25, Lucene idf, k1 1.2 b 0.75, exact doclen, corpus N/avgdl)
  arm fts
  N=$($P -c "select count(*) from docs"); AVG=$($P -c "select avg(ftsdoc_length(to_ftsdoc('english', content))) from docs")
  log "agree N=$N avgdl=$AVG"
  for q in "slovakia" "hungary" "year" "slovakia hungary" "film music album band"; do fq_=$(echo "$q" | sed 's/ / | /g')
    for k in 10 100; do
      $P -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','$fq_') ORDER BY to_ftsdoc('english', content) <=> to_ftsquery('english','$fq_') LIMIT $k) s" > /tmp/ag_fts
      for a in pgts_head pgts_rel; do arm $a
        $P -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$q','docs_idx') LIMIT $k) s" > /tmp/ag_$a
      done; arm fts
      for a in fts pgts_head pgts_rel; do
        ids=$(cat /tmp/ag_$a)
        sc=$($P -c "WITH df AS (SELECT t, (SELECT count(*) FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english', t)) AS df FROM unnest(string_to_array('$q', ' ')) t)
                    SELECT round(sum(fts_bm25(to_ftsdoc('english', d.content), to_ftsquery('english','$fq_'), $N, $AVG,
                                             (SELECT array_agg(df::float8 ORDER BY ord) FROM (SELECT df, row_number() OVER () ord FROM df) x)))::numeric, 4)
                    FROM docs d WHERE d.id = ANY('{$ids}'::bigint[])")
        echo "q=[$q] k=$k arm=$a ids_md5=$(echo $ids | md5sum | cut -c1-8) common_score_sum=$sc ids=$ids" >> $OUT/agree.txt
      done
    done
  done
  log AGREE_DONE
}
case $PH in
  setup) setup ;; clusters) exec >> $OUT/setup.log 2>&1; clusters ;; build) build ;; lat) lat ;; tps) tps ;; cold) cold ;; write) write ;; agree) agree ;;
  all) setup; build; lat; agree; tps; cold; write; log ALL_DONE ;;
esac
