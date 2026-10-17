#!/bin/bash
# cic8.sh <prefix> <port>: @@@ in a join clause over a partitioned table (fts_matchsel sees the parent rel)
set -uo pipefail
PFX=$1; PORT=$2; B=$PFX/bin
D=/nvme/b3/cic8data-$PORT; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_cic_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X -At"
echo "== $($B/postgres --version) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -q -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE pt (id int, d ftsdoc) PARTITION BY RANGE (id)" -c "CREATE TABLE pt1 PARTITION OF pt FOR VALUES FROM (0) TO (1000)" -c "CREATE TABLE pt2 PARTITION OF pt FOR VALUES FROM (1000) TO (3000)" \
  -c "INSERT INTO pt SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 2500) g" -c "CREATE INDEX pt_fts ON pt USING fts (d)" -c "CREATE TABLE o (x int)" -c "INSERT INTO o VALUES (1),(2)" -c "ANALYZE"
$P -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM pt JOIN o ON (pt.d @@@ 'alpha'::ftsquery OR o.x = pt.id)" 2>&1 | head -3
$P -c "SELECT 'join count=' || count(*) FROM pt JOIN o ON (pt.d @@@ 'alpha'::ftsquery OR o.x = pt.id)" 2>&1 | head -2
$P -q -c "CREATE TABLE e (id int, body text)" -c "INSERT INTO e SELECT g, 'alpha doc ' || g FROM generate_series(1, 20000) g" -c "CREATE INDEX e_fts ON e USING fts (to_ftsdoc('simple', body))" -c "ANALYZE e"
echo "expr index, rel is varno 1: $($P -c "EXPLAIN SELECT 1 FROM e WHERE to_ftsdoc('simple', e.body) @@@ 'doc & 17'::ftsquery" | grep -o 'rows=[0-9]*' | head -1)"
echo "expr index, rel is varno 2: $($P -c "EXPLAIN SELECT 1 FROM (VALUES (1)) v(x), e WHERE to_ftsdoc('simple', e.body) @@@ 'doc & 17'::ftsquery" | grep 'Scan on e' | grep -o 'rows=[0-9]*' | head -1)"
$B/pg_ctl -D $D -m fast -w stop >/dev/null
