#!/bin/bash
# i23b.sh: ROADMAP I23 in the reporter's regime: a pure OR that costs hundreds of ms (weak pruning) on 640k longer
# documents.  PG$PGMAJ (default 18, the reporter's), builds v1143 / v1151 / head / head2 (A/A: same tree twice), the
# .so swapped under ONE index.  Correctness first, then ABBA-interleaved rounds; each sample = median of 11 after 3 warm.
set -u
M=${PGMAJ:-18}; O=/nvme/i23b-$M; mkdir -p $O; exec > $O/i23b.log 2>&1; cd $O
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir)
for L in v1143 v1151 head head2; do
  S=$O/src-$L; [ -d $S ] && continue; mkdir -p $S
  case $L in head2) tar xzf /nvme/i23/head.tgz -C $S ;; *) tar xzf /nvme/i23/$L.tgz -C $S ;; esac
  (cd $S && make -s -j16 PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo "BUILD FAIL $L"; exit 1; }
  cp $S/pg_fts.so $O/pg_fts-$L.so; echo "built PG$M $L md5=$(md5sum $O/pg_fts-$L.so | cut -c1-8) GITREV=$(cat $S/GITREV)"
done
(cd $O/src-head && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)
D=$O/data; P=59$M
[ -d $D ] || { $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=8GB\njit=off\nmax_parallel_workers_per_gather=0\nautovacuum=off\n" >> $D/postgresql.conf; }
PS="numactl --physcpubind=16-17 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so
        numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; echo "  [so=$1 $(md5sum $LIB/pg_fts.so | cut -c1-8)]"; }
use head
# 640k docs x 60 tokens, log-uniform over t1..t5000 (Zipf-like); 'build' in 83 docs
$PS -At <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS docs;
SELECT setseed(0.23);
CREATE TABLE docs (id bigint PRIMARY KEY, body text NOT NULL);
INSERT INTO docs
SELECT g, (SELECT string_agg('t' || floor(exp(random() * ln(5000)))::int, ' ') FROM generate_series(1, 60) WHERE g > 0)
          || CASE WHEN g % 7703 = 11 THEN ' build' ELSE '' END
  FROM generate_series(1, 640000) g;
CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE docs;
SELECT 'corpus rows=' || count(*) || ' build=' || count(*) FILTER (WHERE body ~ '\mbuild\M') || ' md5=' || left(md5(string_agg(body, '|' ORDER BY id)), 12) FROM docs;
SQL
QA="build | t10 | t11 | t12 | t13 | t14 | t15 | t16 | t17 | t18 | t19"
QB="build | t40 | t42 | t44 | t46 | t48 | t50 | t52 | t54 | t56 | t58"
rq() { echo "SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ '$1'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> '$1'::ftsquery LIMIT 10;"; }
ids() { $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" ${2:+-c "$2"} -c "SELECT coalesce(string_agg(id::text, ','), '<none>') FROM ($(rq "$1" | sed 's/;$//')) s" | tail -1; }
for L in v1143 v1151 head; do use $L >/dev/null
  for q in "$QA" "$QB"; do r=$(ids "$q"); w=$(ids "$q" "SET pg_fts.bestfirst=off")
    echo "  CORR $L [$q] top10=$(echo $r | md5sum | cut -c1-8) n=$(echo $r | tr ',' '\n' | grep -c .) walk_equal=$([ "$r" = "$w" ] && echo yes || echo NO)"; done
done
echo "  heap A=$($PS -At -c "SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc('simple', body), '$QA'::ftsquery)") B=$($PS -At -c "SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc('simple', body), '$QB'::ftsquery)")"
t() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 14); do echo "\\o /dev/null"; rq "$1"; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -11 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[6]}'; }
for r in $(seq ${ROUNDS:-6}); do
  if [ $((r % 2)) = 1 ]; then ORD="v1143 v1151 head head2 head2 head v1151 v1143"; else ORD="head2 head v1151 v1143 v1143 v1151 head head2"; fi
  for L in $ORD; do use $L >/dev/null; sleep 5; echo "T round=$r so=$L A=$(t "$QA") B=$(t "$QB")"; done
done
use head >/dev/null; $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) $(rq "$QA")" | grep -m1 -oE 'shared hit=[0-9]+( read=[0-9]+)?' | sed 's/^/BUFS head A /'
$B/pg_ctl -D $D -w stop >/dev/null
echo I23B_DONE
