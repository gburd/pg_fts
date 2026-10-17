#!/bin/bash
# cic4.sh <prefix> <port>: partial fts index (normal scan + count pushdown), and indcheckxmin with a verified HOT chain
set -uo pipefail
PFX=$1; PORT=$2; B=$PFX/bin
D=/nvme/b3/cic4data-$PORT; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_cic_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X"
echo "== $($B/postgres --version) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -q -c "CREATE EXTENSION pg_fts" -c "CREATE EXTENSION pageinspect" -c "CREATE TABLE p (id int, d ftsdoc)" \
  -c "INSERT INTO p SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 2000) g" \
  -c "CREATE INDEX p_fts ON p USING fts (d) WHERE id <= 100" -c "VACUUM ANALYZE p"
echo "### partial index (id <= 100), 2000 alpha rows"
$P -At -c "SELECT 'fts_count(index)=' || fts_count('p_fts'::regclass, 'alpha'::ftsquery)" 2>&1 | head -2
$P -c "SET enable_seqscan=off" -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM p WHERE d @@@ 'alpha'::ftsquery AND id <= 100" -c "SELECT count(*) AS partial_q FROM p WHERE d @@@ 'alpha'::ftsquery AND id <= 100"
$P -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM p WHERE d @@@ 'alpha'::ftsquery" -c "SELECT count(*) AS full_q FROM p WHERE d @@@ 'alpha'::ftsquery"
echo "### indcheckxmin with a HOT chain"
$P -q -c "CREATE TABLE h (id int primary key, d ftsdoc) WITH (fillfactor = 50)" -c "INSERT INTO h SELECT g, to_ftsdoc('simple', 'alpha ' || g) FROM generate_series(1, 50) g" -c "VACUUM h"
cat > /nvme/b3/cic4-a.sql <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT 'A sees ' || count(*) FROM h;
SELECT pg_sleep(4);
SELECT 'checkxmin=' || indcheckxmin FROM pg_index WHERE indexrelid = 'h_fts'::regclass;
EXPLAIN (COSTS OFF) SELECT count(*) FROM h WHERE d @@@ 'alpha'::ftsquery;
SELECT 'A pushdown alpha=' || count(*) FROM h WHERE d @@@ 'alpha'::ftsquery;
SELECT 'A pushdown omega=' || count(*) FROM h WHERE d @@@ 'omega'::ftsquery;
SELECT 'A truth alpha=' || count(*) FILTER (WHERE fts_match(d, 'alpha'::ftsquery)) || ' omega=' || count(*) FILTER (WHERE fts_match(d, 'omega'::ftsquery)) FROM h;
COMMIT;
SQL
$P -At -f /nvme/b3/cic4-a.sql &
sleep 1
$P -q -c "UPDATE h SET d = to_ftsdoc('simple', 'omega') WHERE id = 1"
$P -At -c "SELECT 'hot chain: ' || string_agg(lp || ':' || coalesce(t_ctid::text,'') || ':' || (t_infomask2 & 16384 <> 0)::text || '/' || (t_infomask2 & 32768 <> 0)::text, ' ') FROM heap_page_items(get_raw_page('h', 0)) WHERE lp IN (1, 51)"
$P -q -c "CREATE INDEX h_fts ON h USING fts (d)"
$P -At -c "SELECT 'B checkxmin=' || indcheckxmin FROM pg_index WHERE indexrelid = 'h_fts'::regclass"
wait
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo CIC4_DONE
