#!/bin/bash
# cic5.sh <prefix> <port>: partial-index count pushdown truth check; partitioned parent; expression index in a join
set -uo pipefail
PFX=$1; PORT=$2; B=$PFX/bin
D=/nvme/b3/cic5data-$PORT; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_cic_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X"
echo "== $($B/postgres --version) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -q -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE p (id int, d ftsdoc)" \
  -c "INSERT INTO p SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 2000) g" \
  -c "CREATE INDEX p_fts ON p USING fts (d) WHERE id <= 100" -c "VACUUM ANALYZE p"
$P -At -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM p WHERE d @@@ 'alpha'::ftsquery" -c "SELECT 'partial: pushdown=' || count(*) FROM p WHERE d @@@ 'alpha'::ftsquery" -c "SELECT 'partial: truth=' || count(*) FROM p WHERE fts_match(d, 'alpha'::ftsquery)"
$P -q -c "CREATE TABLE pt (id int, d ftsdoc) PARTITION BY RANGE (id)" -c "CREATE TABLE pt1 PARTITION OF pt FOR VALUES FROM (0) TO (1000)" -c "CREATE TABLE pt2 PARTITION OF pt FOR VALUES FROM (1000) TO (3000)" \
  -c "INSERT INTO pt SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 2500) g" -c "CREATE INDEX pt_fts ON pt USING fts (d)" -c "ANALYZE pt"
$P -At -c "EXPLAIN SELECT id FROM pt WHERE d @@@ 'alpha & 17'::ftsquery" -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM pt WHERE d @@@ 'alpha'::ftsquery" -c "SELECT 'partitioned count=' || count(*) FROM pt WHERE d @@@ 'alpha'::ftsquery"
$P -q -c "CREATE TABLE e (id int, body text)" -c "INSERT INTO e SELECT g, 'alpha doc ' || g FROM generate_series(1, 20000) g" -c "CREATE INDEX e_fts ON e USING fts (to_ftsdoc('simple', body))" -c "ANALYZE e"
echo "-- expression index, table second in a join (1 = estimated rows from the index, 100 = tsmatchsel default)"
$P -At -c "EXPLAIN SELECT 1 FROM (VALUES (1)) v(x), e WHERE to_ftsdoc('simple', e.body) @@@ 'doc & 17'::ftsquery" | grep -E "Scan on e|Filter|Cond" | head -3
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo CIC5_DONE
