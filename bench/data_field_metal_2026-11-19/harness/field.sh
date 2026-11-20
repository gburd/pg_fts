#!/bin/bash
# field.sh: pg_fts 1.18.0 vs pg_textsearch / pg_search / VectorChord-bm25 / GIN on EC2 metal,
# Fedora 45, XFS on local NVMe.  bench/PROTOCOL_FIELD_METAL_2026-11-19.md.
# One host runs every arm of a major; exactly one cluster runs at a time; every arm has its own
# PostgreSQL prefix (a copy of ONE build: identical postgres md5), its own data directory and its
# own copy of the table, so a planner never chooses between two engines' indexes.
#   usage: field.sh <phase> [major]     phases: setup | build | lat | agree | tps | cold | all
#   majors: 18 (every engine) and 19 (pg_fts, pg_textsearch main, GIN)
# Inputs in /tmp/in: pg_fts-1.18.0.zip, pgts_v151.tgz, pgts_main.tgz, pg_search_18*.rpm,
# vchord zips, mbench2.c, corpus.py.  Output in /nvme/out/<major>/.
set -uo pipefail
PH=${1:-all}; MAJ=${2:-18}
OUT=/nvme/out/$MAJ; mkdir -p $OUT /nvme/out
IN=/tmp/in
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a $OUT/run.log; }
case $MAJ in
  18) ARMS=${ARMS:-"fts pgts_rel pgts_main psearch psearch_pn vchord gin"} ; PGV=18.7 ;;
  19) ARMS=${ARMS:-"fts pgts_main gin"} ; PGV=19.0 ;;
esac
hoststate() {
  log "hoststate $1: $(/nvme/mbench2 2>&1 | tail -1) | load $(cut -d' ' -f1-3 /proc/loadavg) | thp $(cat /sys/kernel/mm/transparent_hugepage/enabled) | no_turbo $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a) | gov $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
}
pfx() { echo /nvme/pg${MAJ}_$1; }          # per-arm prefix
dat() { echo /nvme/data${MAJ}_$1; }        # per-arm data directory

# ---------------------------------------------------------------------------------------------
setup_host() {   # once per host: OS state, tools, PostgreSQL builds, corpus
  exec >> /nvme/out/setup.log 2>&1
  log "host $(uname -m) $(uname -r) $(lscpu | sed -n 's/^Model name: *//p' | head -1) nproc=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G microcode=$(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')"
  log "os $(. /etc/os-release; echo $PRETTY_NAME)"
  numactl -H 2>/dev/null | head -3 | tee -a /nvme/out/run.log
  # preflight (protocol: THP never, governor performance, Intel turbo off; recorded, not hidden)
  echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag > /dev/null
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee $g > /dev/null 2>&1; done
  [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null
  log "perf counters: $(perf stat -e cycles true 2>&1 | grep -E 'cycles' | head -1 | tr -s ' ')"
  gcc -O2 -o /nvme/mbench2 $IN/mbench2.c && hoststate start
  cd /nvme
  for V in 18.7 19.0; do M=${V%%.*}
    [ -x /nvme/pg$M/bin/postgres ] && continue
    curl -sfLO https://ftp.postgresql.org/pub/source/v$V/postgresql-$V.tar.bz2 || { log "PG $V DOWNLOAD FAILED"; exit 1; }
    tar xjf postgresql-$V.tar.bz2; (cd postgresql-$V && ./configure --prefix=/nvme/pg$M --with-icu CFLAGS="-O2 -g -fno-omit-frame-pointer" > /nvme/cfg$M.log 2>&1 \
      && make -s -j$(nproc) > /nvme/mk$M.log 2>&1 && make -s install > /dev/null && for c in pg_prewarm pg_buffercache; do (cd contrib/$c && make -s install > /dev/null); done) \
      || { log "PG $V BUILD FAILED"; tail -20 /nvme/mk$M.log; exit 1; }
    log "pg $(/nvme/pg$M/bin/postgres --version) configure=$(/nvme/pg$M/bin/pg_config --configure | tr -d "'")"
  done
  # corpus (pinned HF dataset), md5 must match
  python3 -m venv /nvme/venv; /nvme/venv/bin/pip -q install pyarrow huggingface_hub
  CORPUS_N=${CORPUS_N:-} /nvme/venv/bin/python3 $IN/corpus.py
  m=$(md5sum /nvme/c.tsv | cut -c1-32); log "corpus md5=$m rows=$(wc -l < /nvme/c.tsv)"
  if [ -z "${CORPUS_N:-}" ]; then case $m in f5939e85*) ;; *) log "CORPUS MD5 MISMATCH"; exit 1 ;; esac; else log "SMOKE corpus N=$CORPUS_N (md5 not checked)"; fi
  log SETUP_HOST_DONE
}

setup_arms() {   # per major: one prefix per arm with only that engine installed, then clusters
  exec >> $OUT/setup.log 2>&1
  # no server from an earlier or failed run may hold the socket (each arm uses port 5432)
  for d in /nvme/data*_*; do [ -f $d/postmaster.pid ] && /nvme/pg$MAJ/bin/pg_ctl -D $d -w stop -m fast > /dev/null 2>&1; done
  for a in $ARMS; do P0=$(pfx $a); [ -d $P0 ] || cp -a /nvme/pg$MAJ $P0; done
  log "postgres binaries identical across arms: $(for a in $ARMS; do md5sum $(pfx $a)/bin/postgres; done | cut -c1-32 | sort -u | wc -l) distinct md5"
  for a in $ARMS; do P0=$(pfx $a); LIB=$($P0/bin/pg_config --pkglibdir); SHR=$($P0/bin/pg_config --sharedir)
    case $a in
      fts)
        echo "567dde01410ea79e07e99a02b0633337cadcb38116146663e78405ddf52dd0d1  $IN/pg_fts-1.18.0.zip" | sha256sum -c - || { log "PG_FTS ZIP SHA MISMATCH"; exit 1; }
        S=/nvme/src${MAJ}_fts; [ -d $S ] || { mkdir -p $S; unzip -qo $IN/pg_fts-1.18.0.zip -d $S; }
        (cd $S/pg_fts-1.18.0 && make -s PG_CONFIG=$P0/bin/pg_config -j$(nproc) > /nvme/fts$MAJ.mk.log 2>&1 && make -s PG_CONFIG=$P0/bin/pg_config install > /dev/null) || { log "PG_FTS BUILD FAILED"; exit 1; }
        log "arm fts: pg_fts 1.18.0 so=$(md5sum $LIB/pg_fts.so | cut -c1-8) sm=$(grep -o 'SM_VERSION_STRING "[0-9.]*"' $S/pg_fts-1.18.0/vendor/sm.h)" ;;
      pgts_rel|pgts_main)
        t=$IN/pgts_v151.tgz; [ $a = pgts_main ] && t=$IN/pgts_main.tgz
        S=/nvme/src${MAJ}_$a; [ -d $S ] || { mkdir -p $S; tar xzf $t -C $S; }
        (cd $S && make -s PG_CONFIG=$P0/bin/pg_config -j$(nproc) > /nvme/$a$MAJ.mk.log 2>&1 && make -s PG_CONFIG=$P0/bin/pg_config install > /dev/null 2>&1) || { log "$a BUILD FAILED"; tail -5 /nvme/$a$MAJ.mk.log; exit 1; }
        log "arm $a: $(cat $S/GITREV) $(grep -o "default_version = '[^']*'" $S/pg_textsearch.control) so=$(md5sum $LIB/pg_textsearch.so | cut -c1-8)" ;;
      psearch|psearch_pn)
        R=$(ls $IN/pg_search_18-0.27.0-1PARADEDB.el10.$(uname -m).rpm); log "arm $a rpm sha256 $(sha256sum $R | cut -c1-16) $(basename $R)"
        X=/nvme/rpm_psearch; [ -d $X ] || { mkdir -p $X; (cd $X && rpm2cpio $R | cpio -idm --quiet); }
        cp $X/usr/pgsql-18/lib/pg_search.so $LIB/; cp $X/usr/pgsql-18/share/extension/pg_search* $SHR/extension/
        # pg_search 0.27.0's control file requires pgvector; v0.8.7 (latest) from its tag, as the 1.11.0 run did
        V=/nvme/src${MAJ}_${a}_pgvector; [ -d $V ] || { mkdir -p $V; tar xzf $IN/pgvector_v087.tgz -C $V; }
        (cd $V && make -s PG_CONFIG=$P0/bin/pg_config -j$(nproc) > /nvme/pgvector_$a.mk.log 2>&1 && make -s PG_CONFIG=$P0/bin/pg_config install > /dev/null 2>&1) || { log "PGVECTOR BUILD FAILED"; exit 1; }
        log "arm $a: pgvector $(cat $V/GITREV)"
        log "arm $a: pg_search so=$(md5sum $LIB/pg_search.so | cut -c1-8) ldd-missing=$(ldd $LIB/pg_search.so | grep -c 'not found')" ;;
      vchord)
        for z in $IN/postgresql-18-pg-tokenizer_0.1.1_$(uname -m)-linux-gnu.zip $IN/postgresql-18-vchord-bm25_0.3.0_$(uname -m)-linux-gnu.zip; do
          log "arm vchord zip sha256 $(sha256sum $z | cut -c1-16) $(basename $z)"; X=/nvme/zip_$(basename $z .zip); [ -d $X ] || { mkdir -p $X; unzip -qo $z -d $X; }
          find $X -name "*.so" -exec cp {} $LIB/ \; ; find $X -name "*.sql" -exec cp {} $SHR/extension/ \; ; find $X -name "*.control" -exec cp {} $SHR/extension/ \;
        done
        log "arm vchord: so=$(md5sum $LIB/vchord_bm25.so $LIB/pg_tokenizer.so 2>/dev/null | cut -c1-8 | tr '\n' ' ') ldd-missing=$(ldd $LIB/vchord_bm25.so $LIB/pg_tokenizer.so 2>/dev/null | grep -c 'not found')" ;;
      gin) log "arm gin: built in" ;;
    esac
  done
  for a in $ARMS; do
    D=$(dat $a); BB=$(pfx $a)/bin; [ -f $D/.field_ready ] && continue
    [ -d $D ] && mv $D /nvme/trash_${MAJ}_${a}_$RANDOM
    $BB/initdb -D $D -U postgres --no-locale -E UTF8 > /dev/null
    PRE=pg_prewarm
    case $a in pgts_*) PRE="pg_prewarm,pg_textsearch" ;; psearch*) PRE="pg_prewarm,pg_search" ;; vchord) PRE="pg_prewarm,pg_tokenizer" ;; esac
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
    $BB/pg_ctl -D $D -l $D/server.log -w start > /dev/null || { log "CLUSTER $a FAILED TO START"; tail -5 $D/server.log; exit 1; }
    $BB/psql -h /tmp -U postgres -X -q -c "CREATE TABLE docs(id bigint PRIMARY KEY, content text)" -c "\\copy docs FROM '/nvme/c.tsv' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\b')" -c "VACUUM (FREEZE, ANALYZE) docs" -c "CREATE EXTENSION pg_prewarm" -c "CREATE EXTENSION pg_buffercache"
    case $a in
      fts) E="CREATE EXTENSION pg_fts" ;; pgts_*) E="CREATE EXTENSION pg_textsearch" ;; psearch*) E="CREATE EXTENSION pg_search CASCADE" ;;
      vchord) E="CREATE EXTENSION pg_tokenizer CASCADE; CREATE EXTENSION vchord_bm25 CASCADE" ;; gin) E="SELECT 1" ;;
    esac
    $BB/psql -h /tmp -U postgres -X -q -v ON_ERROR_STOP=1 -c "$E" || { log "CREATE EXTENSION FAILED for $a"; exit 1; }
    log "cluster $a rows=$($BB/psql -h /tmp -U postgres -X -At -c 'select count(*) from docs') ext=$($BB/psql -h /tmp -U postgres -X -At -c "select string_agg(extname||' '||extversion, ',') from pg_extension where extname not in ('plpgsql','pg_prewarm','pg_buffercache')")"
    $BB/pg_ctl -D $D -w stop > /dev/null; touch $D/.field_ready
  done
  log SETUP_ARMS_DONE
}

# one cluster at a time; arm X uses prefix pfx X and data dat X
CUR=""
arm() {
  [ "$CUR" = "$1" ] && return
  for x in $ARMS; do $(pfx $x)/bin/pg_ctl -D $(dat $x) -w stop -m fast > /dev/null 2>&1; done
  B=$(pfx $1)/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
  $B/pg_ctl -D $(dat $1) -l $(dat $1)/server.log -w start > /dev/null || { log "ARM $1 FAILED TO START"; exit 1; }; CUR=$1
}
# every relation other than the heap, its toast and pkey: what an engine's index costs on disk
rels() { $P -c "select coalesce(sum(pg_relation_size(c.oid)),0) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname not in ('pg_catalog','information_schema','pg_toast') and c.relkind in ('i','r','t','m') and c.relname not in ('docs','docs_pkey','docs_pos','docs_pos_pkey','fts_pos')"; }
t0() { date +%s.%N; }; el() { echo "$(date +%s.%N)-$1" | bc; }
build() {
  exec >> $OUT/build.log 2>&1
  for a in $ARMS; do arm $a
    case $a in
      fts)
        s=$(t0); $P -c "CREATE INDEX docs_idx ON docs USING fts (to_ftsdoc('english', content))"
        log "build fts expr s=$(el $s) size=$($P -c "select pg_relation_size('docs_idx')")"
        s=$(t0); $P -c "SELECT fts_vacuum('docs_idx')" > /dev/null; log "fts_vacuum s=$(el $s) size=$($P -c "select pg_relation_size('docs_idx')")"
        $P -c "CREATE TABLE docs_pos (id bigint PRIMARY KEY, content text)" -c "INSERT INTO docs_pos SELECT * FROM docs" -c "VACUUM (FREEZE, ANALYZE) docs_pos"
        s=$(t0); $P -c "CREATE INDEX fts_pos ON docs_pos USING fts (to_ftsdoc('english', content)) WITH (positions = on)"
        log "build fts positions s=$(el $s) size=$($P -c "select pg_relation_size('fts_pos')")" ;;
      pgts_*)
        s=$(t0); $P -c "CREATE INDEX docs_idx ON docs USING bm25(content) WITH (text_config='english')" 2>&1 | grep -v "too long" | tail -2
        log "build $a s=$(el $s) size=$($P -c "select pg_relation_size('docs_idx')") all_rels_bytes=$(rels)" ;;
      psearch|psearch_pn)
        opt="'stemmer=english'"; [ $a = psearch_pn ] && opt="'stemmer=english', 'pnorms=true'"
        s=$(t0); $P -c "CREATE INDEX docs_idx ON docs USING paradedb (id, (content::pdb.simple($opt)))" 2>&1 | tail -3
        log "build $a ($opt) s=$(el $s) size=$($P -c "select pg_relation_size('docs_idx')") all_rels_bytes=$(rels) def=$($P -c "select pg_get_indexdef('docs_idx'::regclass)")" ;;
      vchord)
        $P -c "ALTER DATABASE postgres SET search_path TO \"\$user\", public, tokenizer_catalog, bm25_catalog"; arm gin; arm vchord
        $P -c "SELECT create_text_analyzer('en_ana', \$\$
pre_tokenizer = \"unicode_segmentation\"
[[character_filters]]
to_lowercase = {}
[[character_filters]]
unicode_normalization = \"nfkd\"
[[token_filters]]
skip_non_alphanumeric = {}
[[token_filters]]
stopwords = \"nltk_english\"
[[token_filters]]
stemmer = \"english_porter2\"
\$\$)" > /dev/null
        s=$(t0); $P -c "SELECT create_custom_model('en_model', \$\$
table = 'docs'
column = 'content'
text_analyzer = 'en_ana'
\$\$)" > /dev/null; m=$(el $s)
        $P -c "SELECT create_tokenizer('en', \$\$
text_analyzer = 'en_ana'
model = 'en_model'
\$\$)" > /dev/null
        $P -c "ALTER TABLE docs ADD COLUMN emb bm25vector"
        s=$(t0); $P -c "UPDATE docs SET emb = tokenize(content, 'en')"; tk=$(el $s)
        $P -c "VACUUM (FREEZE, ANALYZE) docs"
        s=$(t0); $P -c "CREATE INDEX docs_idx ON docs USING bm25 (emb bm25_ops)"; ix=$(el $s)
        log "build vchord model_s=$m tokenize_s=$tk index_s=$ix size=$($P -c "select pg_relation_size('docs_idx')") all_rels_bytes=$(rels)" ;;
      gin)
        # PostgreSQL's documented form for ranked search (docs 12.2.2): a stored tsvector
        # column, so ts_rank reads it instead of re-parsing the text of every match
        h0=$($P -c "select pg_table_size('docs')")
        s=$(t0); $P -c "ALTER TABLE docs ADD COLUMN tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED"; col=$(el $s)
        $P -c "VACUUM (FREEZE, ANALYZE) docs"
        s=$(t0); $P -c "CREATE INDEX docs_idx ON docs USING gin (tsv)"; ix=$(el $s)
        log "build gin column_s=$col index_s=$ix size=$($P -c "select pg_relation_size('docs_idx')") heap_growth_bytes=$(( $($P -c "select pg_table_size('docs')") - h0 ))" ;;
    esac
    $P -c "VACUUM ANALYZE docs"
  done
  log BUILD_DONE
}

# ---- band SQL per arm ------------------------------------------------------------------------
fq() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','$1') ORDER BY to_ftsdoc('english', content) <=> to_ftsquery('english','$1') LIMIT $2) s"; }
tq() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$1','docs_idx') LIMIT $2) s"; }
tb() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE content @@ to_tsquery('english','$1') ORDER BY content <@> to_bm25query('$2','docs_idx') LIMIT $3) s"; }
tc() { echo "SELECT count(*) FROM (WITH f AS MATERIALIZED (SELECT id, content FROM docs WHERE content @@ to_tsquery('english','$1')) SELECT id FROM f ORDER BY content <@> to_bm25query('$2','docs_idx') LIMIT $3) s"; }
pq() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE $1 ORDER BY pdb.score(id) DESC LIMIT $2) s"; }
vq() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY emb <&> to_bm25query('docs_idx', tokenize('$1', 'en')) LIMIT $2) s"; }
gq() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE tsv @@ to_tsquery('english','$1') ORDER BY ts_rank(tsv, to_tsquery('english','$1')) DESC LIMIT $2) s"; }
bands() {   # name|sql for arm $1 (an arm that cannot express a band omits it; tables say n/a)
  case $1 in
  fts|fts_aa)
    echo "rare_k10|$(fq slovakia 10)"; echo "mid_k10|$(fq hungary 10)"
    echo "common_k10|$(fq year 10)"; echo "common_k100|$(fq year 100)"; echo "common_k1000|$(fq year 1000)"
    echo "or2_k10|$(fq 'slovakia | hungary' 10)"; echo "or4_k10|$(fq 'film | music | album | band' 10)"
    echo "and_k10|$(fq 'slovakia & hungary' 10)"; echo "and_us_k10|$(fq 'united & states' 10)"; echo "and_ww_k10|$(fq 'world & war' 10)"
    echo "not_k10|$(fq 'hungary & !slovakia' 10)"
    echo "phrase_us_k10|$(fq '"united states"' 10 | sed 's/FROM docs WHERE/FROM docs_pos WHERE/')"; echo "phrase_ww_k10|$(fq '"world war"' 10 | sed 's/FROM docs WHERE/FROM docs_pos WHERE/')"
    echo "count_common|SELECT count(*) FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','year')" ;;
  pgts_*)
    echo "rare_k10|$(tq slovakia 10)"; echo "mid_k10|$(tq hungary 10)"
    echo "common_k10|$(tq year 10)"; echo "common_k100|$(tq year 100)"; echo "common_k1000|$(tq year 1000)"
    echo "or2_k10|$(tq 'slovakia hungary' 10)"; echo "or4_k10|$(tq 'film music album band' 10)"
    echo "and_k10|$(tb 'slovakia & hungary' 'slovakia hungary' 10)"; echo "and_us_k10|$(tb 'united & states' 'united states' 10)"; echo "and_ww_k10|$(tb 'world & war' 'world war' 10)"
    echo "not_k10|$(tb 'hungary & !slovakia' 'hungary' 10)"
    echo "phrase_us_k10|$(tb 'united <-> states' 'united states' 10)"; echo "phrase_ww_k10|$(tb 'world <-> war' 'world war' 10)"
    echo "and_k10_cte|$(tc 'slovakia & hungary' 'slovakia hungary' 10)"; echo "and_us_k10_cte|$(tc 'united & states' 'united states' 10)"; echo "and_ww_k10_cte|$(tc 'world & war' 'world war' 10)"
    echo "not_k10_cte|$(tc 'hungary & !slovakia' 'hungary' 10)"
    echo "phrase_us_k10_cte|$(tc 'united <-> states' 'united states' 10)"; echo "phrase_ww_k10_cte|$(tc 'world <-> war' 'world war' 10)"
    echo "count_common|SELECT count(*) FROM docs WHERE content @@ to_tsquery('english','year')" ;;
  psearch*)
    echo "rare_k10|$(pq "content ||| 'slovakia'" 10)"; echo "mid_k10|$(pq "content ||| 'hungary'" 10)"
    echo "common_k10|$(pq "content ||| 'year'" 10)"; echo "common_k100|$(pq "content ||| 'year'" 100)"; echo "common_k1000|$(pq "content ||| 'year'" 1000)"
    echo "or2_k10|$(pq "content ||| 'slovakia hungary'" 10)"; echo "or4_k10|$(pq "content ||| 'film music album band'" 10)"
    echo "and_k10|$(pq "content &&& 'slovakia hungary'" 10)"; echo "and_us_k10|$(pq "content &&& 'united states'" 10)"; echo "and_ww_k10|$(pq "content &&& 'world war'" 10)"
    echo "not_k10|$(pq "content &&& 'hungary' AND NOT content &&& 'slovakia'" 10)"
    echo "phrase_us_k10|$(pq "content ### 'united states'" 10)"; echo "phrase_ww_k10|$(pq "content ### 'world war'" 10)"
    echo "count_common|SELECT count(*) FROM docs WHERE content ||| 'year'" ;;
  vchord)
    echo "rare_k10|$(vq slovakia 10)"; echo "mid_k10|$(vq hungary 10)"
    echo "common_k10|$(vq year 10)"; echo "common_k100|$(vq year 100)"; echo "common_k1000|$(vq year 1000)"
    echo "or2_k10|$(vq 'slovakia hungary' 10)"; echo "or4_k10|$(vq 'film music album band' 10)" ;;
  gin)
    echo "rare_k10|$(gq slovakia 10)"; echo "mid_k10|$(gq hungary 10)"
    echo "common_k10|$(gq year 10)"; echo "common_k100|$(gq year 100)"; echo "common_k1000|$(gq year 1000)"
    echo "or2_k10|$(gq 'slovakia | hungary' 10)"; echo "or4_k10|$(gq 'film | music | album | band' 10)"
    echo "and_k10|$(gq 'slovakia & hungary' 10)"; echo "and_us_k10|$(gq 'united & states' 10)"; echo "and_ww_k10|$(gq 'world & war' 10)"
    echo "not_k10|$(gq 'hungary & !slovakia' 10)"
    echo "phrase_us_k10|$(gq 'united <-> states' 10)"; echo "phrase_ww_k10|$(gq 'world <-> war' 10)"
    echo "count_common|SELECT count(*) FROM docs WHERE tsv @@ to_tsquery('english','year')" ;;
  esac
}
cluster_of() { case $1 in fts_aa) echo fts ;; *) echo $1 ;; esac; }
prewarm() { for t in docs docs_pos; do $P -c "SELECT 1 FROM pg_class WHERE relname='$t'" | grep -q 1 || continue; $P -c "SELECT pg_prewarm('$t')" > /dev/null; for i in $($P -c "select indexrelid::regclass from pg_index where indrelid='$t'::regclass"); do $P -c "SELECT pg_prewarm('$i')" > /dev/null; done; done; }

# ---- correctness gate: counts, k rows, regex truth -------------------------------------------
gate() {
  for a in $ARMS; do arm $a
    for t in slovakia hungary year; do
      case $a in
        fts) c=$($P -c "SET enable_seqscan=off" -c "SELECT count(*) FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','$t')" | tail -1) ;;
        pgts_*) c=$($P -c "SELECT count(*) FROM docs WHERE content @@ to_tsquery('english','$t')") ;;
        psearch*) c=$($P -c "SELECT count(*) FROM docs WHERE content ||| '$t'") ;;
        gin) c=$($P -c "SET enable_seqscan=off" -c "SELECT count(*) FROM docs WHERE tsv @@ to_tsquery('english','$t')" | tail -1) ;;
        vchord) c=n/a ;;
      esac
      echo "arm=$a term=$t count=$c" | tee -a $OUT/gate.txt
    done
  done
  arm gin
  for t in slovakia hungary; do echo "regex term=$t count=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\m$t\\M'")" | tee -a $OUT/gate.txt; done
  echo "regex term=years? count=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\myears?\\M'")" | tee -a $OUT/gate.txt
  log GATE_DONE
}

# ---- latency ---------------------------------------------------------------------------------
lat() {
  hoststate lat_start
  LARMS="$ARMS"; case " $ARMS " in *" fts "*) LARMS="$ARMS fts_aa" ;; esac
  if [ ! -f $OUT/explain.txt ]; then
    for a in $ARMS; do arm $a; prewarm
      bands $a | while IFS='|' read -r n sql; do { echo "== $a $n"; $P -c "EXPLAIN $sql"; } >> $OUT/explain.txt 2>&1; done
    done
  fi
  arms=($LARMS); na=${#arms[@]}
  for pass in $(seq 1 ${LAT_PASSES:-5}); do
    # rotate the arm order each pass; fts_aa sits opposite fts in the rotation
    ord=""; for i in $(seq 0 $((na-1))); do ord="$ord ${arms[$(( (i + pass - 1) % na ))]}"; done
    log "lat pass $pass order:$ord"
    for la in $ord; do a=$(cluster_of $la); arm $a; prewarm
      bands $a | while IFS='|' read -r n sql; do
        grep -q "^pass=$pass arm=$la band=$n " $OUT/latency.txt 2>/dev/null && continue
        grep -qx "$n" /tmp/timedout_${MAJ}_$a 2>/dev/null && { echo "pass=$pass arm=$la band=$n rows=TIMEOUT(300s) median_last5= raw=[skipped: timed out in an earlier pass]" | tee -a $OUT/latency.txt; continue; }
        { echo "SET statement_timeout = '${STMT_TIMEOUT:-300s}';"; echo '\timing on'; echo "$sql;"; } > /tmp/p1.sql
        o=$($P -f /tmp/p1.sql 2>&1); t1=$(echo "$o" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | head -1)
        if echo "$o" | grep -q "statement timeout"; then
          echo "pass=$pass arm=$la band=$n rows=TIMEOUT(300s) median_last5= raw=[$t1]" | tee -a $OUT/latency.txt; echo "$n" >> /tmp/timedout_${MAJ}_$a; continue; fi
        if echo "$o" | grep -q "ERROR"; then
          echo "pass=$pass arm=$la band=$n rows=ERROR median_last5= raw=[$(echo "$o" | grep -m1 ERROR | tr '|' '/')]" | tee -a $OUT/latency.txt; echo "$n" >> /tmp/timedout_${MAJ}_$a; continue; fi
        reps=8; awk -v t="${t1:-0}" 'BEGIN{exit !(t > 10000)}' && reps=3
        if awk -v t="${t1:-0}" 'BEGIN{exit !(t > 60000)}'; then
          rows=$(echo "$o" | grep -vE '^Time:|^SET|^$|NOTICE|DETAIL' | sort -u | tr '\n' ',')
          echo "pass=$pass arm=$la band=$n rows=$rows median_last5=$t1 raw=[$t1] reps=1 probe=$t1" | tee -a $OUT/latency.txt; continue
        fi
        { echo "SET statement_timeout = '${STMT_TIMEOUT:-300s}';"; echo '\timing on'; for i in $(seq 1 $reps); do echo "$sql;"; done; } > /tmp/b.sql
        o=$($P -f /tmp/b.sql 2>&1)
        rows=$(echo "$o" | grep -vE '^Time:|^SET|^$' | sort -u | tr '\n' ',')
        ts=$(echo "$o" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | head -$reps | tr '\n' ' ')
        if [ $reps = 8 ]; then med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p); else med=$(echo "$ts" | tr ' ' '\n' | grep . | sort -n | sed -n 2p); fi
        echo "pass=$pass arm=$la band=$n rows=$rows median_last5=$med raw=[$ts] reps=$reps probe=$t1" | tee -a $OUT/latency.txt
      done
    done
  done
  hoststate lat_end; log LAT_DONE
}

# ---- agreement: top-10/100 ids per engine, all rescored with ONE formula ---------------------
agree() {
  arm fts
  N=$($P -c "select count(*) from docs"); AVG=$($P -c "select avg(ftsdoc_length(to_ftsdoc('english', content))) from docs")
  log "agree N=$N avgdl=$AVG"
  for q in "slovakia" "hungary" "year" "slovakia hungary" "film music album band"; do fq_=$(echo "$q" | sed 's/ / | /g')
    for k in 10 100; do
      for a in $ARMS; do arm $a
        case $a in
          fts) s="SELECT id FROM docs WHERE to_ftsdoc('english', content) @@@ to_ftsquery('english','$fq_') ORDER BY to_ftsdoc('english', content) <=> to_ftsquery('english','$fq_') LIMIT $k" ;;
          pgts_*) s="SELECT id FROM docs ORDER BY content <@> to_bm25query('$q','docs_idx') LIMIT $k" ;;
          psearch*) s="SELECT id FROM docs WHERE content ||| '$q' ORDER BY pdb.score(id) DESC LIMIT $k" ;;
          vchord) s="SELECT id FROM docs ORDER BY emb <&> to_bm25query('docs_idx', tokenize('$q', 'en')) LIMIT $k" ;;
          gin) s="SELECT id FROM docs WHERE tsv @@ to_tsquery('english','$fq_') ORDER BY ts_rank(tsv, to_tsquery('english','$fq_')) DESC LIMIT $k" ;;
        esac
        $P -c "SET statement_timeout='600s'" -c "SELECT string_agg(id::text, ',') FROM ($s) x" | tail -1 > /tmp/ag_$a
      done
      arm fts
      for a in $ARMS; do ids=$(cat /tmp/ag_$a)
        [ -z "$ids" ] && { echo "q=[$q] k=$k arm=$a ids_md5= common_score_sum= ids=" >> $OUT/agree.txt; continue; }
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

# ---- settled throughput ----------------------------------------------------------------------
tps() {
  hoststate tps_start
  for a in $ARMS; do bands $a | while IFS='|' read -r n sql; do
      case $n in rare_k10|common_k10|and_us_k10|and_us_k10_cte|count_common) ;; *) continue ;; esac
      echo "$sql;" > /tmp/t${MAJ}_${a}_$n.sql; done; done
  arms=($ARMS); na=${#arms[@]}
  for pass in 1 2; do
    if [ $pass = 1 ]; then ord="$ARMS"; else ord=$(for i in $(seq $((na-1)) -1 0); do echo -n "${arms[$i]} "; done); fi
    for a in $ord; do arm $a
      $P -c "CHECKPOINT" > /dev/null; sync; sleep ${SETTLE:-60}; prewarm
      for f in /tmp/t${MAJ}_${a}_*.sql; do [ -f "$f" ] || continue; n=$(basename $f .sql); n=${n#t${MAJ}_${a}_}
        grep -qx "$n" /tmp/timedout_${MAJ}_$a 2>/dev/null && { echo "pass=$pass arm=$a band=$n SKIPPED(timeout in latency)" | tee -a $OUT/tps.txt; continue; }
        lm=$(grep "^pass=1 arm=$a band=$n " $OUT/latency.txt | grep -o 'median_last5=[0-9.]*' | cut -d= -f2)
        awk -v t="${lm:-0}" 'BEGIN{exit !(t > 1000)}' && { echo "pass=$pass arm=$a band=$n SKIPPED(latency ${lm} ms > 1 s)" | tee -a $OUT/tps.txt; continue; }
        $B/pgbench -h /tmp -U postgres -n -f $f -c 8 -j 8 -T ${WARM:-10} postgres > /dev/null 2>&1
        line="pass=$pass arm=$a band=$n"
        for c in ${CLIENTS:-1 16 64 128 256}; do j=$(( c < 64 ? c : 64 ))
          o=$($B/pgbench -h /tmp -U postgres -n -f $f -c $c -j $j -T ${TPS_T:-30} postgres 2>&1)
          echo "$o" | grep -qiE "aborted|error" && log "TPS WARNING arm=$a band=$n c=$c: $(echo "$o" | grep -m1 -iE 'aborted|error')"
          line="$line c$c=$(echo "$o" | sed -n 's/^tps = \([0-9.]*\).*/\1/p') f$c=$(echo "$o" | sed -n 's/^number of failed transactions: \([0-9]*\).*/\1/p')"
        done; echo "$line" | tee -a $OUT/tps.txt
      done
    done
  done
  hoststate tps_end; log TPS_DONE
}

# ---- cold cache ------------------------------------------------------------------------------
cold() {
  for rep in $(seq 1 ${COLD_REPS:-5}); do for a in $ARMS; do
    bands $a | while IFS='|' read -r n sql; do
      case $n in rare_k10|common_k10|and_k10|and_k10_cte) ;; *) continue ;; esac
      grep -qx "$n" /tmp/timedout_${MAJ}_$a 2>/dev/null && { echo "rep=$rep arm=$a band=$n cold_ms=SKIPPED(timeout in latency)" | tee -a $OUT/cold.txt; continue; }
      arm $a; $B/pg_ctl -D $(dat $a) -w stop -m fast > /dev/null; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
      $B/pg_ctl -D $(dat $a) -l $(dat $a)/server.log -w start > /dev/null
      t=$($P -c "SET statement_timeout = '300s'" -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $sql" 2>&1 | python3 -c "import json,sys
try: print(json.load(sys.stdin)[0]['Execution Time'])
except Exception as e: print('ERR', e)")
      echo "rep=$rep arm=$a band=$n cold_ms=$t" | tee -a $OUT/cold.txt
    done; done; done
  log COLD_DONE
}

case $PH in
  host) setup_host ;; arms) setup_arms ;; build) build ;; gate) gate ;; lat) lat ;; agree) agree ;; tps) tps ;; cold) cold ;;
  major) setup_arms; build; gate; lat; agree; tps; cold; log "MAJOR_${MAJ}_DONE" ;;
  all) setup_host; for m in 18 19; do bash $0 major $m; done; log ALL_DONE ;;
esac
