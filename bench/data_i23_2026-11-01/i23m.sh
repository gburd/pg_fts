#!/bin/bash
# i23.sh: ROADMAP I23 (pure OR 5-8% slower than 1.14.3, Codeberg #6) and the I19b readings skip (1b3ca35).
# One PG cluster per major, ONE index built once; the pg_fts.so is swapped between builds (catalog and on-disk
# format are identical 1.14.3..HEAD), as the reporter did.  Builds: v1143 (1.14.3), v1151 (1.15.1), head
# (1b3ca35), and for the layout question an A/A pair of the SAME tree built twice (head, head2).
# Correctness first (top-10 equal across builds and to bestfirst=off; heap count), then timing:
# each run = median of 21 after 4 warm, in one psql session (\timing); rounds interleave builds in ABBA order.
set -u
M=${PGMAJ:-17}; O=/nvme/i23-$M; mkdir -p $O; exec > $O/i23.log 2>&1
cd $O
date -u; uname -r; lscpu | grep -E "Model name|^CPU\(s\)|Thread|NUMA node\(s\)"; cat /sys/kernel/mm/transparent_hugepage/enabled
B=/nvme/pg$M/bin; LIB=$($B/pg_config --pkglibdir)
# --- build each tree into its own .so (same compiler, same flags) ---
for L in v1143 v1151 head head2; do
  S=$O/src-$L; [ -d $S ] && continue; mkdir -p $S
  case $L in head2) tar xzf /nvme/i23/head.tgz -C $S ;; *) tar xzf /nvme/i23/$L.tgz -C $S ;; esac
  (cd $S && make -s -j16 PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo "BUILD FAIL $L"; exit 1; }
  cp $S/pg_fts.so $O/pg_fts-$L.so; echo "built $L md5=$(md5sum $O/pg_fts-$L.so | cut -c1-8) GITREV=$(cat $S/GITREV 2>/dev/null)"
done
# install SQL from HEAD (1.15.1 catalog == 1.14.3 catalog)
(cd $O/src-head && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)
D=$O/data$M; P=58$M
if [ ! -d $D ]; then
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=4GB\njit=off\nmax_parallel_workers_per_gather=0\nautovacuum=off\n" >> $D/postgresql.conf
fi
PS="numactl --physcpubind=16-17 --membind=0 $B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
# pinned (label: pinned): postmaster and its backends on node 0 cores 8-15, memory node 0; psql on 16-17
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp $O/pg_fts-$1.so $LIB/pg_fts.so; numactl --physcpubind=8-15 --membind=0 $B/pg_ctl -D $D -l $D/log -w start >/dev/null; \
        echo "  [so=$1 $(md5sum $LIB/pg_fts.so | cut -c1-8)]"; }
use head
# reporter's 400k corpus (setup6, setseed 0.6) + 'build' in ~83 rows with no OR term, + zzzx readings shape
$PS -At <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS docs;
SELECT setseed(0.6);
CREATE TABLE docs (id bigint PRIMARY KEY, body text NOT NULL);
INSERT INTO docs
SELECT g, concat_ws(' ',
         'w' || (random()*2000)::int, 'w' || (random()*2000)::int,
         'w' || (random()*2000)::int, 'w' || (random()*2000)::int,
         CASE WHEN random() < 0.25 OR g = 123456 THEN 'apple' END,
         CASE WHEN random() < 0.25 THEN 'banana' END,
         CASE WHEN g = 123456 THEN 'rare' END,
         CASE WHEN g % 4819 = 7 THEN 'build' END)
FROM generate_series(1, 400000) g;
UPDATE docs SET body = regexp_replace(body, '\m(apple|banana|w1|w2|w3|w4|w5|w6|w7|w8)\M', '', 'g') WHERE body ~ '\mbuild\M';
CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE docs;
SELECT 'corpus build_rows=' || count(*) FILTER (WHERE body ~ '\mbuild\M') || ' md5=' || left(md5(string_agg(body, '|' ORDER BY id)), 12) FROM docs;
SQL
QOR="build | apple | banana | w1 | w2 | w3 | w4 | w5 | w6 | w7 | w8"
QRD="(zzzq | zzzx) & (apple | ban:*)"
QT1="zzzq & (apple | ban:*)"
QAND="build & (apple | banana | w1 | w2 | w3 | w4 | w5 | w6 | w7 | w8)"
rq() { echo "SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ '$1'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> '$1'::ftsquery LIMIT 10;"; }
ids() { $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" ${2:+-c "$2"} -c "SELECT coalesce(string_agg(id::text, ','), '<none>') FROM ($(rq "$1" | sed 's/;$//')) s" | tail -1; }
# --- correctness, every build ---
for L in v1143 v1151 head; do use $L
  for q in "$QOR" "$QRD" "$QT1" "$QAND"; do
    r=$(ids "$q"); w=$(ids "$q" "SET pg_fts.bestfirst=off")
    echo "  CORR $L [$q] top10=$(echo $r | md5sum | cut -c1-8) n=$(echo $r | tr ',' '\n' | grep -c .) walk_equal=$([ "$r" = "$w" ] && echo yes || echo NO)"
  done
  echo "  CORR $L heap OR=$($PS -At -c "SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc('simple', body), '$QOR'::ftsquery)") RD=$($PS -At -c "SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc('simple', body), '$QRD'::ftsquery)")"
done
# --- timing ---
t() { { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 25); do echo "\\o /dev/null"; rq "$1"; echo "\\o"; done; } \
      | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -21 | sort -n | awk '{a[NR]=$1} END {printf "%s", a[11]}'; }
bufs() { $PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) $(rq "$1")" | grep -m1 -oE 'shared hit=[0-9]+' ; }
ROUNDS=${ROUNDS:-6}
for r in $(seq $ROUNDS); do
  if [ $((r % 2)) = 1 ]; then ORD="v1143 v1151 head head2 head2 head v1151 v1143"; else ORD="head2 head v1151 v1143 v1143 v1151 head head2"; fi
  for L in $ORD; do use $L >/dev/null; sleep 5
    echo "T round=$r so=$L OR=$(t "$QOR") RD=$(t "$QRD") T1=$(t "$QT1") AND=$(t "$QAND")"
  done
done
for L in v1143 head; do use $L >/dev/null; echo "BUFS $L OR=$(bufs "$QOR") RD=$(bufs "$QRD") T1=$(bufs "$QT1")"; done
$B/pg_ctl -D $D -w stop >/dev/null
echo I23_DONE
