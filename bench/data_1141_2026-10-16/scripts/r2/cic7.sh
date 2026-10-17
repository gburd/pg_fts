#!/bin/bash
# cic7.sh <prefix> <port>: expression index, cancelled CIC, reader session that INSERTed first (loads rd_indexprs)
set -uo pipefail
PFX=$1; PORT=$2; B=$PFX/bin
D=/nvme/b3/cic7data-$PORT; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_cic_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X -At"
echo "== $($B/postgres --version) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -q -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE t (id int, body text)" -c "INSERT INTO t SELECT g, 'alpha doc ' || g FROM generate_series(1, 2000) g" -c "ANALYZE t"
$P -q -c "BEGIN; INSERT INTO t VALUES (3001, 'beta'); SELECT pg_sleep(3); COMMIT;" >/dev/null &
sleep 0.5
$P -q -c "CREATE INDEX CONCURRENTLY t_fts ON t USING fts (to_ftsdoc('simple', body));" 2>&1 &
sleep 0.5
$P -q -c "BEGIN; INSERT INTO t VALUES (3002, 'omega alpha'); SELECT pg_sleep(6); COMMIT;" >/dev/null &
sleep 4
$P -c "SELECT 'state ' || indisready || '/' || indisvalid FROM pg_index WHERE indexrelid = 't_fts'::regclass"
$P -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid()" >/dev/null
sleep 4
$P -c "SELECT 'after cancel ' || indisready || '/' || indisvalid FROM pg_index WHERE indexrelid = 't_fts'::regclass"
cat > /nvme/b3/cic7-r.sql <<'SQL'
SELECT 'fresh session: ' || count(*) FROM t WHERE to_ftsdoc('simple', body) @@@ 'omega'::ftsquery;
INSERT INTO t VALUES (3003, 'zeta');
EXPLAIN (COSTS OFF) SELECT count(*) FROM t WHERE to_ftsdoc('simple', body) @@@ 'omega'::ftsquery;
SELECT 'idx_scan before: ' || idx_scan FROM pg_stat_user_indexes WHERE indexrelname = 't_fts';
SELECT 'after an INSERT in this session: ' || count(*) FROM t WHERE to_ftsdoc('simple', body) @@@ 'omega'::ftsquery;
SELECT pg_stat_force_next_flush();
SELECT 'idx_scan after: ' || idx_scan FROM pg_stat_user_indexes WHERE indexrelname = 't_fts';
SELECT 'alpha via pushdown: ' || count(*) FROM t WHERE to_ftsdoc('simple', body) @@@ 'alpha'::ftsquery;
SELECT 'alpha fts_count: ' || fts_count('t_fts'::regclass, 'alpha'::ftsquery);
SELECT 'fts_count(invalid index): ' || fts_count('t_fts'::regclass, 'omega'::ftsquery);
SELECT 'truth: ' || count(*) FROM t WHERE fts_match(to_ftsdoc('simple', body), 'omega'::ftsquery);
SQL
$P -f /nvme/b3/cic7-r.sql 2>&1
wait
$B/pg_ctl -D $D -m fast -w stop >/dev/null
