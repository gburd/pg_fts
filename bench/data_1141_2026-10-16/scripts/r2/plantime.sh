#!/bin/bash
# Item 3: Planning Time of a 5-term @@@ query, PG 18.6, one data directory restarted under each build.
# Index with >= 7 segments (pending_flush_threshold flushes).  Warm = median of 15 EXPLAIN (SUMMARY) in one
# session after 3 discarded; cold = first EXPLAIN in a fresh session right after a restart, 11 restarts, median.
set -uo pipefail
R=/nvme/b3/repro; PORT=55730; D0=/nvme/b3/plantime-base; D=/nvme/b3/plantime-data
B0=$R/pg-v140/bin
for x in $D $D0; do $B0/pg_ctl -D $x -m immediate -w stop >/dev/null 2>&1; [ -d $x ] && mv $x /nvme/trash_pt_$RANDOM; done
$B0/initdb -D $D0 -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\nshared_buffers=1GB\n" >> $D0/postgresql.conf
$B0/pg_ctl -D $D0 -l $D0/log -w start >/dev/null
P="$B0/psql -h /tmp -p $PORT -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE t (id int, d ftsdoc)" -c "CREATE INDEX t_fts ON t USING fts (d)"
for k in 0 1 2 3 4 5 6; do
  $P -c "SET pg_fts.pending_flush_threshold = 20000" -c "INSERT INTO t SELECT g, to_ftsdoc('simple', (SELECT string_agg('w' || ((g * 7919 + i * 104729) % 5000), ' ') FROM generate_series(1, 20) i)) FROM generate_series($k * 20000 + 1, ($k + 1) * 20000) g"
done
$P -c "VACUUM ANALYZE t"
echo "segments=$($P -c "SELECT fts_index_nsegments('t_fts')") rows=$($P -c "SELECT count(*) FROM t") index=$($P -c "SELECT pg_size_pretty(pg_relation_size('t_fts'))")"
$B0/pg_ctl -D $D0 -w stop >/dev/null
Q="SELECT id FROM t WHERE d @@@ 'w17 & w170 & w1700 & w23 & w230'::ftsquery"
warm() { # $1 bin
  { for i in $(seq 1 18); do echo "EXPLAIN (SUMMARY ON, COSTS OFF) $Q;"; done; } > /nvme/b3/pt.sql
  $1/psql -h /tmp -p $PORT -U postgres -X -q -At -f /nvme/b3/pt.sql | sed -n 's/^Planning Time: \([0-9.]*\) ms/\1/p' | tail -15 | sort -n | sed -n 8p
}
cold() { # $1 bin
  local v=()
  for i in $(seq 1 11); do
    $1/pg_ctl -D $D -m fast -w restart >/dev/null
    v+=($($1/psql -h /tmp -p $PORT -U postgres -X -q -At -c "EXPLAIN (SUMMARY ON, COSTS OFF) $Q" | sed -n 's/^Planning Time: \([0-9.]*\) ms/\1/p'))
  done
  printf "%s\n" "${v[@]}" | sort -n | sed -n 6p
}
for TAG in v140 r2a v140 r2a; do
  B=$R/pg-$TAG/bin
  [ -d $D ] && mv $D /nvme/trash_pt_$RANDOM; cp -a $D0 $D   # every arm starts from the same files
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  PP="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
  echo "$TAG so=$(md5sum $R/pg-$TAG/lib/postgresql/pg_fts.so | cut -c1-8) nseg=$($PP -c "SELECT fts_index_nsegments('t_fts')") est=$($PP -c "EXPLAIN $Q" | grep -o 'rows=[0-9]*' | head -1) actual=$($PP -c "SELECT count(*) FROM ($Q) s")"
  echo "  pending=0: warm $(warm $B) ms, cold $(cold $B) ms"
  $PP -c "SET pg_fts.pending_flush_threshold = 0" -c "INSERT INTO t SELECT g, to_ftsdoc('simple', 'w17 w170 w1700 w23 w230 fresh') FROM generate_series(140001, 140100) g"
  echo "  pending=100: nseg=$($PP -c "SELECT fts_index_nsegments('t_fts')") est=$($PP -c "EXPLAIN $Q" | grep -o 'rows=[0-9]*' | head -1) actual=$($PP -c "SELECT count(*) FROM ($Q) s"); warm $(warm $B) ms, cold $(cold $B) ms"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done
echo PLANTIME_DONE
