#!/bin/bash
# p7.sh: jimdawdy-hub 7d347ff's four still-applicable ideas, each alone on top of main (29397dc C code):
#   p1 tidset_sort_uniq skips the sort on presorted input   (collect path: prefix/phrase/count/bitmap)
#   p2 one dictionary lookup per (term, segment)             (ranked setup)
#   p3 the cursor's block buffer reused across blocks        (every WAND / best-first block)
#   p4 one heap slot for the visibility loop                 (every ranked query, k*4 candidates)
# One cluster, one index per corpus, the .so swapped (base, base2 = A/A, p1..p4); 6 ABBA rounds; each sample the
# median of 11 after 3 warm.  Corpus: 640k x 60 tokens (Zipf, 1 segment; a stable multi-segment index was not
# obtainable: inline flushes trigger the level-0 compactor).
set -u
M=18; O=/nvme/p7; mkdir -p $O; exec > $O/p7.log 2>&1; cd $O
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir)
for L in base base2 p1 p2 p3 p4; do S=$O/src-$L; [ -d $S ] && continue; mkdir -p $S
  case $L in base2) tar xzf /tmp/p7_base.tgz -C $S ;; *) tar xzf /tmp/p7_$L.tgz -C $S ;; esac
  (cd $S && make -s -j16 PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo BUILD FAIL $L; exit 1; }
  cp $S/pg_fts.so $O/pg_fts-$L.so; echo "built $L md5=$(md5sum $O/pg_fts-$L.so | cut -c1-8) GITREV=$(cat $S/GITREV)"; done
(cd $O/src-base && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)
D=$O/data; P=7418
[ -d $D ] || { $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=8GB\njit=off\nmax_parallel_workers_per_gather=0\nautovacuum=off\n" >> $D/postgresql.conf; }
PS="numactl --physcpubind=16-17 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so; numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; }
use base
$PS -At <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
SELECT setseed(0.23);
CREATE TABLE d1 (id bigint PRIMARY KEY, body text NOT NULL);
INSERT INTO d1 SELECT g, (SELECT string_agg('t' || floor(exp(random() * ln(5000)))::int, ' ') FROM generate_series(1, 60) WHERE g > 0)
  FROM generate_series(1, 640000) g;
CREATE INDEX d1_fts ON d1 USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE d1;
SELECT 'segments d1=' || fts_index_nsegments('d1_fts');
SQL
# query shapes: [table|query|k]
QS=("d1#t5#10" "d1#t5#100" "d1#t300#10" "d1#t10 | t11#10" "d1#t10 & t11#10" "d1#t10 & t49:*#10" "d1#t10 | t11 | t12 | t13#100" "d1#t2000 | t3000 | t4000#10" "d1#t20 & t30 & t40#10" "d1#t10 | t11 | t12 | t13#10")
rq() { IFS='#' read -r tb q k <<< "$1"; echo "SELECT id FROM $tb WHERE to_ftsdoc('simple', body) @@@ '$q'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> '$q'::ftsquery LIMIT $k;"; }
# correctness first: every build returns the same ids as base, and as bestfirst=off
for L in base p1 p2 p3 p4; do use $L
  for x in "${QS[@]}"; do r=$($PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT md5(string_agg(id::text, ',')) FROM ($(rq "$x" | sed 's/;$//')) s")
    echo "CORR $L [$x] $r"; [ -n "$r" ] || { echo "EMPTY RESULT $L [$x]: $($PS -At -c "SELECT 1 FROM ($(rq "$x" | sed 's/;$//')) s" 2>&1 | tail -1)"; exit 1; }; done
  r=$($PS -At -c "SET enable_seqscan=off" -c "SET enable_indexscan=off" -c "SELECT count(*) FROM d1 WHERE to_ftsdoc('simple', body) @@@ 't10 & t49:*'::ftsquery"); echo "CORR $L [count t10 & t49:*] $r"
done
t() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; rq "$1"; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
tc() { { echo "SET enable_seqscan=off; SET enable_indexscan=off;"; echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; echo "SELECT count(*) FROM d1 WHERE to_ftsdoc('simple', body) @@@ 't10 & t49:*'::ftsquery;"; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
for r in 1 2 3 4 5 6; do
  if [ $((r % 2)) = 1 ]; then ORD="base p1 p2 p3 p4 base2 base2 p4 p3 p2 p1 base"; else ORD="base2 p4 p3 p2 p1 base base p1 p2 p3 p4 base2"; fi
  for L in $ORD; do use $L; sleep 2; line="T round=$r so=$L"; i=0
    for x in "${QS[@]}"; do i=$((i+1)); line="$line q$i=$(t "$x")"; done; line="$line count=$(tc)"; echo "$line"; done; done
$B/pg_ctl -D $D -w stop >/dev/null; echo P7_DONE
