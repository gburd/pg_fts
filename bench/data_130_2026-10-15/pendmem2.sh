#!/bin/bash
# per build: peak RSS + time of ONE backend for a ranked query and a bitmap count, with N pending rows
# usage: pendmem2.sh <pg bin dir>   (pg_fts already installed there)
B=$1; D=/nvme/pm2; P="$B/psql -h /tmp -p 55498 -U postgres -X -q -At"
[ -d $D ] && mv $D $D.old.$$; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55498\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
$P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE docs (id bigserial, d ftsdoc)" -c "INSERT INTO docs(d) SELECT to_ftsdoc('simple','anchorterm doc'||g) FROM generate_series(1,2000) g" -c "CREATE INDEX docs_fts ON docs USING fts (d)" -c "VACUUM docs" >/dev/null
run() { ( $P -c "SELECT pg_backend_pid()" -c "SET enable_seqscan=off" -c "$2" -c "\\timing on" -c "$1" > /tmp/pm2.out 2>&1 ) & QP=$!; peak=0; sleep 0.1; pid=$(head -1 /tmp/pm2.out)
  while kill -0 $QP 2>/dev/null; do r=$(awk '/VmHWM/{print $2}' /proc/$pid/status 2>/dev/null); [ -n "$r" ] && peak=$r; sleep 0.05; done
  echo "$(sed -n 2p /tmp/pm2.out) VmHWM=${peak}kB $(grep Time /tmp/pm2.out)"; }
for n in 8000 24000; do
  $P -c "INSERT INTO docs(d) SELECT to_ftsdoc('simple','churnterm w'||(g%50)) FROM generate_series(1,$n) g" >/dev/null
  echo "pending+=$n: ranked: $(run "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ 'churnterm'::ftsquery ORDER BY d <=> 'churnterm'::ftsquery LIMIT 10) s" "SET enable_bitmapscan=off")"
  echo "pending+=$n: bitmap: $(run "SELECT count(id) FROM docs WHERE d @@@ 'churnterm'::ftsquery" "SET enable_indexscan=off")"
done
$B/pg_ctl -D $D -w stop >/dev/null
