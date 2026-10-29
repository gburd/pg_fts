#!/bin/bash
# m4.sh <phase> -- ROADMAP M4 + M1.  The competitor set TIN's article measured (ParadeDB pg_search 0.25.2,
# pg_textsearch 1.4.0, built-in GIN; PostgreSQL 18.6) plus pg_fts 1.15.0, on TIN's rig: EC2 i7i.8xlarge; each
# engine's postgres in a cgroup limited to CPUs 0-7 and 32 GB for queries (builds get the RAM the article gave each
# engine: pg_search 64, pg_textsearch 128, GIN 64; pg_fts 32); the Benchmarker's defaults except
# max_parallel_workers=8, shared_buffers=24GB, maintenance_work_mem=24GB; engines one at a time.  Load generator:
# pgbench -M extended (the query text is a bound parameter, as the Benchmarker sends it), 16 clients, on CPUs 8-31.
# Corpus: Stack Overflow questions + answers, archive.org stackexchange_20251231 dump (TIN used its own 85 GB /
# 150M-document Stack Exchange export, which is not published).  Trace: m4prep.py, 1,254 substrings of 2-15 words x
# {AND, OR, phrase} = 3,762 queries, the article's count.
# Phases: prep | base | engine <fts|pdb|pgts|gin> (build + check + W1 mixed + W2 AND/phrase + W3 OR with 1,000
# UPDATE/s for 600 s) | report
set -uo pipefail
W=/nvme/m4smoke/w; mkdir -p $W; PG=/nvme/pg18; SE=/nvme/m4smoke/se
log() { echo "$(date +%T) $*" | tee -a $W/m4.log; }
CONF="port=6500
unix_socket_directories='/tmp'
listen_addresses=''
max_connections=200
shared_buffers=24GB
maintenance_work_mem=24GB
max_parallel_workers=8
effective_cache_size=4GB
work_mem=256MB
checkpoint_completion_target=0.9
wal_buffers=256MB
random_page_cost=1.1
effective_io_concurrency=200
max_parallel_workers_per_gather=2
max_worker_processes=16
jit=off
max_wal_size=32GB
autovacuum=on
shared_preload_libraries='pg_search,pg_textsearch'"
startpg() {  # startpg <datadir> <MemoryMax>
  sudo systemctl stop pg-m4 >/dev/null 2>&1; sudo systemctl reset-failed pg-m4 >/dev/null 2>&1
  sudo systemd-run --unit=pg-m4 --uid=admin --gid=admin -p AllowedCPUs=0-7 -p MemoryMax=$2 -p MemorySwapMax=0 \
    $PG/bin/postgres -D $1 >/dev/null 2>&1
  for i in $(seq 1 300); do $PG/bin/pg_isready -h /tmp -p 6500 -q && return 0; sleep 1; done; log "PG DID NOT START $1"; return 1
}
setmem() { sudo systemctl set-property --runtime pg-m4 MemoryMax=$1; }
stoppg() { $PG/bin/pg_ctl -D $1 -m fast -w -t 600 stop >/dev/null 2>&1; sudo systemctl stop pg-m4 >/dev/null 2>&1; sudo systemctl reset-failed pg-m4 >/dev/null 2>&1; }
P() { $PG/bin/psql -X -q -At -h /tmp -p 6500 -U postgres -d m4 -v ON_ERROR_STOP=1 "$@"; }
peak() { cat /sys/fs/cgroup/system.slice/pg-m4.service/memory.peak 2>/dev/null | awk '{printf "%.1f GB", $1/2^30}'; }

prep() {
  log "prep: 7z md5 $(md5sum $SE/stackoverflow.com.7z | cut -c1-32) (archive.org lists 941031010fcd66350695b00fa37651b5)"
  7z l $SE/stackoverflow.com.7z | tail -8 >> $W/m4.log
  s=$(date +%s); 7z x -so $SE/stackoverflow.com.7z Posts.xml 2>/dev/null | python3 /tmp/m4/m4prep.py $SE/posts.tsv $SE/queries.tsv 2>> $W/m4.log
  log "prep done in $(( $(date +%s)-s )) s: posts.tsv $(du -h $SE/posts.tsv | cut -f1), $(wc -l < $SE/posts.tsv) rows; queries $(wc -l < $SE/queries.tsv); md5 posts $(md5sum $SE/posts.tsv | cut -c1-12) queries $(md5sum $SE/queries.tsv | cut -c1-12)"
}
base() {
  D=$W/base; [ -d $D ] && { stoppg $D; mv $D /nvme/trash_m4_$RANDOM; }
  $PG/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null; echo "$CONF" >> $D/postgresql.conf
  startpg $D 64G || exit 1
  $PG/bin/createdb -h /tmp -p 6500 -U postgres m4
  P -c "CREATE TABLE posts (id bigint PRIMARY KEY, title text, content text)" -c "CREATE TABLE qs (id int PRIMARY KEY, kind text, q text)"
  s=$(date +%s)
  P -c "\\copy posts FROM '$SE/posts.tsv' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\b')" -c "\\copy qs FROM '$SE/queries.tsv' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\b')"
  P -c "VACUUM (FREEZE, ANALYZE) posts" -c "VACUUM ANALYZE qs" -c "CHECKPOINT"
  log "base loaded in $(( $(date +%s)-s )) s: $(P -c 'select count(*) from posts') posts, heap+toast $(P -c "select pg_size_pretty(pg_table_size('posts'))"), queries $(P -c 'select string_agg(kind||'"'"' '"'"'||n, '"'"', '"'"') from (select kind, count(*) n from qs group by 1 order by 1) s')"
  stoppg $D
}
ddl() { case $1 in
  fts)  echo "CREATE EXTENSION pg_fts; CREATE INDEX posts_ix ON posts USING fts (to_ftsdoc('english', content)) WITH (positions = on);" ;;
  pdb)  echo "CREATE EXTENSION pg_search CASCADE; CREATE INDEX posts_ix ON posts USING bm25 (id, content) WITH (key_field = 'id');" ;;
  pgts) echo "CREATE EXTENSION pg_textsearch; CREATE INDEX posts_ix ON posts USING bm25 (content) WITH (text_config = 'english');" ;;
  gin)  echo "CREATE INDEX posts_ix ON posts USING gin (to_tsvector('english', content));" ;;
esac; }
# one trace entry -> the query each engine runs (\$1 = the plain-word trace text; pgbench binds :qtext as \$1)
qsql() { case "$1:$2" in
  fts:and)    echo "SELECT id FROM posts WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english', replace(:qtext, ' ', ' & ')) ORDER BY to_ftsdoc('english', content) <=> to_ftsquery('english', replace(:qtext, ' ', ' & ')) LIMIT 10" ;;
  fts:or)     echo "SELECT id FROM posts WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english', replace(:qtext, ' ', ' | ')) ORDER BY to_ftsdoc('english', content) <=> to_ftsquery('english', replace(:qtext, ' ', ' | ')) LIMIT 10" ;;
  fts:phrase) echo "SELECT id FROM posts WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english', '\"' || :qtext || '\"') ORDER BY to_ftsdoc('english', content) <=> to_ftsquery('english', '\"' || :qtext || '\"') LIMIT 10" ;;
  pdb:and)    echo "SELECT id FROM posts WHERE content &&& :qtext ORDER BY pdb.score(id) DESC LIMIT 10" ;;
  pdb:or)     echo "SELECT id FROM posts WHERE content ||| :qtext ORDER BY pdb.score(id) DESC LIMIT 10" ;;
  pdb:phrase) echo "SELECT id FROM posts WHERE content ### :qtext ORDER BY pdb.score(id) DESC LIMIT 10" ;;
  pgts:or)    echo "SELECT id FROM posts ORDER BY content <@> to_bm25query(:qtext, 'posts_ix') LIMIT 10" ;;
  gin:and)    echo "SELECT id FROM posts WHERE to_tsvector('english', content) @@ plainto_tsquery('english', :qtext) ORDER BY ts_rank_cd(to_tsvector('english', content), plainto_tsquery('english', :qtext)) DESC LIMIT 10" ;;
  gin:or)     echo "SELECT id FROM posts WHERE to_tsvector('english', content) @@ to_tsquery('english', replace(:qtext, ' ', ' | ')) ORDER BY ts_rank_cd(to_tsvector('english', content), to_tsquery('english', replace(:qtext, ' ', ' | '))) DESC LIMIT 10" ;;
  gin:phrase) echo "SELECT id FROM posts WHERE to_tsvector('english', content) @@ phraseto_tsquery('english', :qtext) ORDER BY ts_rank_cd(to_tsvector('english', content), phraseto_tsquery('english', :qtext)) DESC LIMIT 10" ;;
  *) echo "" ;;
esac; }
mkscripts() {  # mkscripts <engine> <tag> <kinds...> -> pgbench -f args (one file per kind, equal weight); empty if
  # the engine cannot run every kind (a workload it cannot complete is n/a, not a subset)
  E=$1; T=$2; shift 2; a=""
  for k in "$@"; do [ -z "$(qsql $E $k)" ] && return 0; done
  for k in "$@"; do
    s=$(qsql $E $k)
    n=$(P -c "select count(*) from qs where kind = '$k'"); lo=$(P -c "select min(id) from qs where kind = '$k'")
    # the trace ids of one kind are lo, lo+3, lo+6, ... (m4prep writes and/or/phrase in turn)
    printf '\\set r random(0, %d)\n\\set qid %d + 3 * :r\nSELECT q AS qtext FROM qs WHERE id = :qid \\gset\n%s;\n' $((n-1)) $lo "$s" > $W/${E}_${T}_$k.sql
    a="$a -f $W/${E}_${T}_$k.sql@1"
  done; echo "$a"; }
bench() {  # bench <engine> <tag> <seconds> <kinds...>
  E=$1; T=$2; S=$3; shift 3; args=$(mkscripts $E $T "$@")
  [ -z "$args" ] && { log "$E $T: n/a (no supported query kind among: $*)"; return; }
  taskset -c 8-31 $PG/bin/pgbench -h /tmp -p 6500 -U postgres -n -M extended -c 16 -j 8 -T 5 $args m4 > $W/${E}_${T}_warm.txt 2>&1
  ( cd $W && taskset -c 8-31 $PG/bin/pgbench -h /tmp -p 6500 -U postgres -n -M extended -c 16 -j 8 -T 10 -l --log-prefix=lat_${E}_${T} $args m4 > $W/${E}_${T}.txt 2>&1 )
  log "$E $T: $(grep -E 'number of transactions actually|number of failed|latency average|tps =' $W/${E}_${T}.txt | tr '\n' ' ') | $(pct $W/lat_${E}_${T})"
}
pct() { cat $1.* 2>/dev/null | awk '{print $3}' | sort -n | awk '{a[NR]=$1} END {if (NR==0) {print "no log"; exit}; printf "n=%d p50=%.1fms p90=%.1fms p99=%.1fms", NR, a[int(NR*0.5)]/1000, a[int(NR*0.9)]/1000, a[int(NR*0.99)]/1000}'; }
check() {  # each supported kind: the plan uses the engine's index, and how many of 30 trace entries return >= 1 row
  E=$1
  for k in and or phrase; do
    s=$(qsql $E $k); [ -z "$s" ] && { log "$E check $k: n/a (unsupported)"; continue; }
    ps=$(echo "$s" | sed 's/:qtext/$1/g')
    q1=$(P -c "select q from qs where kind = '$k' order by id limit 1")
    plan=$(P -c "PREPARE p(text) AS $ps" -c "EXPLAIN (COSTS OFF) EXECUTE p('$q1')" 2>&1 | grep -oE "Index Scan using posts_ix|Bitmap Index Scan on posts_ix|Custom Scan \([^)]*\)|Seq Scan on posts" | sort -u | tr '\n' ',')
    res=$(P -c "SET statement_timeout = '600s'" -c "DO \$\$
DECLARE r record; n int; ne int := 0; tot int := 0;
BEGIN
  FOR r IN SELECT q FROM qs WHERE kind = '$k' ORDER BY id LIMIT 30 LOOP
    EXECUTE 'SELECT count(*) FROM (' || \$q\$$ps\$q\$ || ') s' INTO n USING r.q;
    tot := tot + n; IF n > 0 THEN ne := ne + 1; END IF;
  END LOOP;
  RAISE NOTICE 'nonempty=% rows=%', ne, tot;
END \$\$" 2>&1 | grep -oE "nonempty=[0-9]+ rows=[0-9]+|ERROR.*")
    log "$E check $k: plan [$plan]; of 30 trace entries: $res"
  done
}
engine() {
  E=$1; D=$W/d_$E; [ -d $D ] && { stoppg $D; mv $D /nvme/trash_m4_$RANDOM; }
  log "engine $E: copy base ($(du -sh $W/base | cut -f1))"; cp -a $W/base $D
  BUILDMEM=32G; case $E in pdb|gin) BUILDMEM=64G;; pgts) BUILDMEM=128G;; esac
  startpg $D $BUILDMEM || return 1
  log "engine $E: versions $(P -c "select string_agg(name||' '||default_version, ', ') from pg_available_extensions where name in ('pg_fts','pg_search','pg_textsearch')") | $($PG/bin/postgres --version)"
  log "engine $E: build (MemoryMax $BUILDMEM): $(ddl $E)"
  s=$(date +%s); P -c "SET client_min_messages=warning" -c "$(ddl $E)" > $W/${E}_build.txt 2>&1; rc=$?
  b=$(( $(date +%s)-s )); P -c "VACUUM ANALYZE posts" -c "CHECKPOINT" >/dev/null
  log "engine $E: build rc=$rc in $b s ($(awk -v b=$b 'BEGIN{printf "%dm%02ds", b/60, b%60}')); index $(P -c "select pg_size_pretty(pg_relation_size('posts_ix'))") (all non-pkey relations added: $(P -c "select pg_size_pretty(sum(pg_total_relation_size(c.oid))) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname not in ('pg_catalog','information_schema','pg_toast') and c.relkind in ('i','r','m') and c.relname not in ('posts','posts_pkey','qs','qs_pkey')")); peak cgroup memory $(peak)"
  [ $rc = 0 ] || { tail -3 $W/${E}_build.txt | tee -a $W/m4.log; stoppg $D; return 1; }
  stoppg $D; startpg $D 32G || return 1
  [ $E = gin ] && P -c "ALTER SYSTEM SET statement_timeout = '60s'" -c "SELECT pg_reload_conf()" >/dev/null
  check $E
  bench $E W1_mixed 300 and or phrase
  bench $E W2_and_phrase 300 and phrase
  # W3: OR top-10 with a concurrent client targeting 1,000 UPDATE/s for 600 s (M1: the same write form for every engine)
  args=$(mkscripts $E W3 or)
  if [ -n "$args" ]; then
    printf '\\set id random(1, %d)\nUPDATE posts SET content = content || '"' edited'"' WHERE id = (SELECT id FROM posts WHERE id >= :id ORDER BY id LIMIT 1);\n' $(P -c "select max(id) from posts") > $W/upd.sql
    ( cd $W && taskset -c 8-31 $PG/bin/pgbench -h /tmp -p 6500 -U postgres -n -M extended -c 4 -j 2 -R 100 -T 15 -f $W/upd.sql m4 > $W/${E}_W3_upd.txt 2>&1 ) &
    up=$!
    ( cd $W && taskset -c 8-31 $PG/bin/pgbench -h /tmp -p 6500 -U postgres -n -M extended -c 16 -j 8 -T 15 -l --log-prefix=lat_${E}_W3 $args m4 > $W/${E}_W3.txt 2>&1 )
    wait $up
    log "$E W3_or_with_updates: readers $(grep -E 'number of transactions actually|latency average|tps =' $W/${E}_W3.txt | tr '\n' ' ') | $(pct $W/lat_${E}_W3) | updates $(grep -E 'number of transactions actually|number of failed|skipped|tps =' $W/${E}_W3_upd.txt | tr '\n' ' ')"
    log "$E after W3: index $(P -c "select pg_size_pretty(pg_relation_size('posts_ix'))"); peak cgroup memory $(peak)"
  else log "$E W3: n/a"; fi
  stoppg $D
  log "engine $E DONE"
}
case ${1:-} in
  prep) prep ;; base) base ;; engine) engine $2 ;;
  *) echo "usage: m4.sh prep|base|engine <e>"; exit 1 ;;
esac
