#!/bin/bash
# cbab.sh: do the CBMC fixes (wand_load_block column check, integer-domain
# guards, BMW bound operation order) + sparsemap 5.8.4 cost the ranked paths?
# 640k Zipf corpus, one index, .so swapped: main (a6938d1) vs cbmc (this tree),
# plus cbmc built twice (A/A).  Correctness first: top-k score lists equal the
# exhaustive ranking for both builds.
set -u
M=18; O=/nvme/cbab; mkdir -p $O; exec > $O/cbab.log 2>&1; cd $O
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir)
for L in main cbmc cbmcb; do S=$O/src-$L; [ -d $S ] && continue; mkdir -p $S
  case $L in main) tar xzf $O/main.tgz -C $S ;; *) tar xzf $O/cbmc.tgz -C $S ;; esac
  (cd $S && make -s -j16 PG_CONFIG=$B/pg_config with_llvm=no >/dev/null 2>&1) || { echo BUILD FAIL $L; exit 1; }; cp $S/pg_fts.so $O/pg_fts-$L.so; done
echo "so md5: main $(md5sum < $O/pg_fts-main.so | cut -c1-8) cbmc $(md5sum < $O/pg_fts-cbmc.so | cut -c1-8) cbmcb $(md5sum < $O/pg_fts-cbmcb.so | cut -c1-8); colsfit in cbmc src: $(grep -c bm25_for_cols_fit $O/src-cbmc/pg_fts_am_scan.c), in main: $(grep -c bm25_for_cols_fit $O/src-main/pg_fts_am_scan.c)"
(cd $O/src-cbmc && make -s install PG_CONFIG=$B/pg_config with_llvm=no >/dev/null 2>&1)
D=$O/data; P=6519
[ -d $D ] || { $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=8GB\njit=off\nmax_parallel_workers_per_gather=0\nautovacuum=off\n" >> $D/postgresql.conf; }
PS="numactl --physcpubind=16-17 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so; numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; }
use cbmc
$PS -At <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS docs;
SELECT setseed(0.23);
CREATE TABLE docs (id bigint PRIMARY KEY, body text NOT NULL);
INSERT INTO docs SELECT g, (SELECT string_agg('t' || floor(exp(random() * ln(5000)))::int, ' ') FROM generate_series(1, 60) WHERE g > 0)
  FROM generate_series(1, 640000) g;
CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE docs;
SQL
echo "segments: $($PS -At -c "SELECT fts_index_nsegments('docs_fts')")"
# '#' separates specs (a '|' is the ftsquery OR)
QS=("t10 | t11" "t40 | t300" "t10 | t11 | t12" "t10" "t10 | t11 | t12 | t13" "t10 & t11")
for L in main cbmc; do use $L; for q in "${QS[@]}"; do for k in 10 100; do
  r=$($PS -At -c "SELECT md5(string_agg(round(score::numeric,9)::text, ',' ORDER BY score DESC)) FROM fts_search('docs_fts', '$q'::ftsquery, $k)")
  x=$($PS -At -c "SELECT md5(string_agg(round(s::numeric,9)::text, ',' ORDER BY s DESC)) FROM (SELECT score s FROM fts_search('docs_fts', '$q'::ftsquery, 100000) ORDER BY score DESC LIMIT $k) z")
  n=$($PS -At -c "SELECT count(*) FROM fts_search('docs_fts', '$q'::ftsquery, $k)")
  echo "  CORR $L [$q] k=$k n=$n topk_scores_equal_exhaustive=$([ "$r" = "$x" ] && echo yes || echo NO)"; done; done; done
t() { { echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; echo "SELECT count(*) FROM fts_search('docs_fts', '$1'::ftsquery, $2);"; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
for r in 1 2 3 4 5 6; do
  if [ $((r % 2)) = 1 ]; then ORD="main cbmc cbmcb cbmcb cbmc main"; else ORD="cbmcb cbmc main main cbmc cbmcb"; fi
  for L in $ORD; do use $L; sleep 3; line="T round=$r so=$L"; i=0
    for q in "${QS[@]}"; do i=$((i+1)); line="$line q${i}k10=$(t "$q" 10) q${i}k100=$(t "$q" 100)"; done; echo "$line"; done; done
$B/pg_ctl -D $D -w stop >/dev/null; echo CBAB_DONE
