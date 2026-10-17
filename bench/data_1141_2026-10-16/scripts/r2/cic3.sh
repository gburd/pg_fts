#!/bin/bash
# cic3.sh <prefix> <port>: count pushdown vs a partial fts index and an indcheckxmin fts index
set -uo pipefail
PFX=$1; PORT=$2; B=$PFX/bin
D=/nvme/b3/cic3data-$PORT; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_cic_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X"
echo "== $($B/postgres --version) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -q -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE p (id int, d ftsdoc)" \
  -c "INSERT INTO p SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 2000) g" \
  -c "CREATE INDEX p_fts ON p USING fts (d) WHERE id <= 100" -c "VACUUM ANALYZE p"
echo "### partial index (id <= 100), 2000 alpha rows"
$P -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM p WHERE d @@@ 'alpha'::ftsquery"
$P -At -c "SELECT 'pushdown count=' || count(*) FROM p WHERE d @@@ 'alpha'::ftsquery"
$P -At -c "SELECT 'truth=' || count(*) FROM p WHERE fts_match(d, 'alpha'::ftsquery)"
echo "### indcheckxmin: HOT update, then CREATE INDEX while a REPEATABLE READ snapshot sees the old version"
$P -q -c "CREATE TABLE h (id int primary key, d ftsdoc)" -c "INSERT INTO h SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 50) g" -c "VACUUM h"
cat > /nvme/b3/cic3-a.sql <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) AS a_rows FROM h;
SELECT pg_sleep(3);
SELECT i.indcheckxmin FROM pg_index i WHERE i.indexrelid = 'h_fts'::regclass;
EXPLAIN (COSTS OFF) SELECT count(*) FROM h WHERE d @@@ 'omega'::ftsquery;
SELECT 'A pushdown omega=' || count(*) FROM h WHERE d @@@ 'omega'::ftsquery;
SELECT 'A truth omega=' || count(*) FROM h WHERE fts_match(d, 'omega'::ftsquery);
SELECT 'A pushdown alpha=' || count(*) FROM h WHERE d @@@ 'alpha'::ftsquery;
SELECT 'A truth alpha=' || count(*) FROM h WHERE fts_match(d, 'alpha'::ftsquery);
COMMIT;
SQL
$P -At -f /nvme/b3/cic3-a.sql &
sleep 1
$P -q -c "UPDATE h SET d = to_ftsdoc('simple', 'omega') WHERE id = 1" -c "SELECT n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='h'"
$P -q -c "CREATE INDEX h_fts ON h USING fts (d)"
wait
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo CIC3_DONE
