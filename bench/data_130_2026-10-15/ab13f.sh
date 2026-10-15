#!/bin/bash
# A/B on one Debian EC2 host: pg_fts released 1.12.1 (PGXN zip sha256 7aef7247...)
# vs the 1.13.0
# candidate.  ONE data dir, arms alternate, 3 rounds; medians of 9 timed runs inside one
# psql session; correctness (top-10 ids + counts identical) asserted before any timing.
set -uo pipefail
exec > /nvme/ab13f.log 2>&1
B=/nvme/pg17/bin; cd /nvme
if [ ! -x $B/postgres ]; then
  curl -sfLO https://ftp.postgresql.org/pub/source/v17.10/postgresql-17.10.tar.bz2; tar xjf postgresql-17.10.tar.bz2
  (cd postgresql-17.10 && ./configure --prefix=/nvme/pg17 CFLAGS="-O2 -g -fno-omit-frame-pointer" >/nvme/cfg.log 2>&1 && make -s -j16 >/nvme/mk.log 2>&1 && make -s install >/dev/null && (cd contrib/pg_prewarm && make -s install >/dev/null))
fi
gcc -O2 -o /nvme/mbench2 /tmp/mbench2.c 2>/dev/null
mb() { [ -x /nvme/mbench2 ] && echo "mbench2 $1: $(/nvme/mbench2 2>&1 | tail -1)"; }
mb before
for a in base cand; do [ -d /nvme/so_$a ] && continue; mkdir -p /nvme/src_$a; done
[ -f /nvme/so_base.so ] || { unzip -qo /tmp/pg_fts-1.12.1.zip -d /nvme/src_base; (cd /nvme/src_base/pg_fts-1.12.1 && make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1); cp /nvme/src_base/pg_fts-1.12.1/pg_fts.so /nvme/so_base.so; }
mv /nvme/so_cand.so /nvme/so_cand_old.so 2>/dev/null; [ -d /nvme/src_cand ] && mv /nvme/src_cand /nvme/src_cand.old.$$; mkdir -p /nvme/src_cand; [ -f /nvme/so_cand.so ] || { tar xzf /tmp/fts_tree.tgz -C /nvme/src_cand; (cd /nvme/src_cand && make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1); cp /nvme/src_cand/pg_fts.so /nvme/so_cand.so; }
# both arms' SQL scripts installed (1.13.0 tree installs every version's scripts)
(cd /nvme/src_base/pg_fts-1.12.1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1); (cd /nvme/src_cand && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1)
echo "base so $(md5sum /nvme/so_base.so | cut -c1-8)  cand so $(md5sum /nvme/so_cand.so | cut -c1-8) $(cat /nvme/src_cand/GITREV)"
LIB=$($B/pg_config --pkglibdir); D=/nvme/abdata; PORT=55470
P() { $B/psql -h /tmp -p $PORT -U postgres -X -q -At "$@"; }
use() { $B/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; cp /nvme/so_$1.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/log -w start >/dev/null; ARM=$1; }
if [ ! -d $D ]; then
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=8GB\nmax_parallel_maintenance_workers=8\nmaintenance_work_mem=2GB\nautovacuum=off\n" >> $D/postgresql.conf
  use base
  P -c "CREATE EXTENSION pg_fts VERSION '1.12.1'" -c "CREATE EXTENSION pg_prewarm" >/dev/null
  P -c "CREATE TABLE d (id int, t text)" -c "INSERT INTO d SELECT g, 'w' || (g % 97) || ' u' || g || ' v' || (g::bigint * 31 % 400000) || CASE WHEN g % 5 = 0 THEN ' rare' ELSE ' common' END || CASE WHEN g % 11 = 0 THEN ' hot dog' WHEN g % 11 = 1 THEN ' dog hot' ELSE '' END || ' ' || repeat('pad ', g % 13) FROM generate_series(1, 2000000) g" >/dev/null
  P -c "CREATE INDEX d_fts ON d USING fts (to_ftsdoc('simple', t)) WITH (positions = on)" -c "VACUUM ANALYZE d" >/dev/null
fi
echo "rows $(P -c 'select count(*) from d') nseg $(P -c "select fts_index_nsegments('d_fts')") size $(P -c "select pg_size_pretty(pg_relation_size('d_fts'))")"
QS=("rare" "common" "rare & w5" "w1 | w2 | w3 | rare" "\"hot dog\"" "common & !w3" "\"hot dog\" & w7" "rare & !\"hot dog\"" "w5 & !\"hot dog\"" "w5 | \"hot dog\"")
Q() { echo "SELECT count(*) FROM (SELECT id FROM d WHERE to_ftsdoc('simple', t) @@@ '$1'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> '$1'::ftsquery LIMIT 10) s"; }
QB() { echo "SELECT count(id) FROM d WHERE to_ftsdoc('simple', t) @@@ '$1'::ftsquery"; }
# correctness gate (queries go through files: they contain double quotes)
bad=0
for q in "${QS[@]}"; do
  for arm in base cand; do use $arm
    { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "SELECT string_agg(id::text, ',') FROM ($(Q "$q" | sed 's/^SELECT count(\*) FROM (//; s/) s$//')) s;"; } > /nvme/c1.sql
    { echo "SET enable_seqscan=off; SET enable_indexscan=off;"; echo "$(QB "$q");"; } > /nvme/c2.sql
    eval "top_$arm=\$(P -f /nvme/c1.sql | tail -1)"; eval "cnt_$arm=\$(P -f /nvme/c2.sql | tail -1)"
  done
  ok=same; [ "$top_base" = "$top_cand" ] || { ok=TOPDIFF; bad=1; }; [ "$cnt_base" = "$cnt_cand" ] || { ok="$ok CNTDIFF"; bad=1; }
  [ "${cnt_base:-0}" -gt 0 ] 2>/dev/null || { ok="$ok ZERO"; bad=1; }
  echo "correct [$q] $ok count=$cnt_base/$cnt_cand top=$(echo $top_base | cut -c1-40)"
done
[ $bad = 0 ] || { echo "CORRECTNESS FAILED: no timing"; echo AB13_DONE; exit 1; }
echo "CORRECTNESS bad=$bad"
for round in 1 2 3; do for arm in base cand; do use $arm; P -c "SELECT pg_prewarm('d_fts')" -c "SELECT pg_prewarm('d')" >/dev/null
  for kind in ranked bitmap; do line="r$round $arm $kind"
    for q in "${QS[@]}"; do
      if [ $kind = ranked ]; then pre="SET enable_seqscan=off; SET enable_bitmapscan=off;"; sql=$(Q "$q"); else pre="SET enable_seqscan=off; SET enable_indexscan=off;"; sql=$(QB "$q"); fi
      { echo "$pre"; echo '\timing on'; for i in $(seq 1 12); do echo "$sql;"; done; } > /nvme/ab.sql
      m=$(P -f /nvme/ab.sql 2>&1 | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | tail -9 | sort -n | sed -n 5p); line="$line | $m"
    done; echo "$line"; done; done; done
echo "queries: ${QS[*]}"
mb after
echo AB13_DONE
