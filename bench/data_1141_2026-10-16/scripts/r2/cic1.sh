#!/bin/bash
# cic1.sh <prefix> <port>: fts_matchsel / count pushdown against an invalid or incomplete fts index
set -uo pipefail
PFX=$1; PORT=$2; B=$PFX/bin
D=/nvme/b3/cic1data-$PORT; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_cic_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X -v ON_ERROR_STOP=0"
echo "== $($B/postgres --version) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -q <<'SQL'
CREATE EXTENSION pg_fts;
CREATE TABLE t (id int, body text);
INSERT INTO t SELECT g, 'alpha doc ' || g FROM generate_series(1, 1000) g;
ANALYZE t;
SQL
CHK="SELECT c.relname, i.indisvalid, i.indisready, pg_relation_size(c.oid) AS bytes FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 't'::regclass;
EXPLAIN (COSTS OFF) SELECT id FROM t WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery;
SELECT count(*) AS alpha_count FROM t WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery;
SELECT count(*) AS omega_count FROM t WHERE to_ftsdoc('simple', body) @@@ 'omega'::ftsquery;
SELECT id FROM t WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery ORDER BY id LIMIT 2;"
echo "### A: CIC blocked in phase 1 (writer holds RowExclusiveLock)"
$P -q -c "BEGIN; INSERT INTO t VALUES (2001, 'beta'); SELECT pg_sleep(6); COMMIT;" >/dev/null &
sleep 1
$P -q -c "CREATE INDEX CONCURRENTLY t_fts ON t USING fts (to_ftsdoc('simple', body));" &
sleep 2
$P -c "SELECT wait_event_type, wait_event, left(query,40) FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();" -c "$CHK"
wait
$P -c "$CHK"
$P -q -c "DROP INDEX t_fts;"
echo "### B: CIC cancelled after indisready, before validate (a concurrent writer's row is missing)"
$P -q -c "BEGIN; INSERT INTO t VALUES (2002, 'beta'); SELECT pg_sleep(4); COMMIT;" >/dev/null &
sleep 1
$P -q -c "CREATE INDEX CONCURRENTLY t_fts ON t USING fts (to_ftsdoc('simple', body));" &
sleep 1
$P -q -c "BEGIN; INSERT INTO t VALUES (2003, 'omega alpha'); SELECT pg_sleep(8); COMMIT;" >/dev/null &
sleep 4
$P -c "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();" -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();"
sleep 6
echo "(writer committed; 1001 alpha rows and 1 omega row are live)"
$P -c "$CHK"
$P -c "SET pg_fts.enable_count_pushdown = off" -c "SET enable_indexscan=off" -c "SET enable_bitmapscan=off" -c "SELECT count(*) AS seq_alpha FROM t WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery" 2>&1 | grep -v "unrecognized"
$P -q -c "DROP INDEX t_fts;"
echo "### C: CIC blocked in WaitForOlderSnapshots (repeatable-read reader holds a snapshot)"
$P -q -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT 1 FROM t LIMIT 1; SELECT pg_sleep(6); COMMIT;" >/dev/null &
sleep 1
$P -q -c "CREATE INDEX CONCURRENTLY t_fts ON t USING fts (to_ftsdoc('simple', body));" &
sleep 2
$P -c "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();" -c "$CHK"
wait
$P -c "$CHK"
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo CIC1_DONE
