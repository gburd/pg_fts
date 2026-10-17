#!/bin/bash
# cic1.sh <prefix> <port>: fts_matchsel / count pushdown against an invalid or incomplete fts index
set -uo pipefail
PFX=$1; PORT=$2; B=$PFX/bin
D=/nvme/b3/cic2data-$PORT; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_cic_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X -v ON_ERROR_STOP=0"
echo "== $($B/postgres --version) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -q <<'SQL'
CREATE EXTENSION pg_fts;
CREATE TABLE t (id int, body text, d ftsdoc);
INSERT INTO t SELECT g, 'alpha doc ' || g, to_ftsdoc('simple', 'alpha doc ' || g) FROM generate_series(1, 20000) g;
ANALYZE t;
SQL
chk() {
  $P -c "SELECT c.relname, i.indisvalid, i.indisready, pg_relation_size(c.oid) AS bytes FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 't'::regclass"
  $P -c "EXPLAIN SELECT id FROM t WHERE d @@@ 'doc & 17'::ftsquery"
  $P -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM t WHERE d @@@ 'omega'::ftsquery"
  $P -At -c "SELECT 'alpha_count=' || count(*) FROM t WHERE d @@@ 'alpha'::ftsquery"
  $P -At -c "SELECT 'omega_count=' || count(*) FROM t WHERE d @@@ 'omega'::ftsquery"
  $P -At -c "SELECT 'ids=' || string_agg(id::text, ',') FROM (SELECT id FROM t WHERE d @@@ 'omega | beta'::ftsquery ORDER BY id) s"
}
echo "### A: CIC blocked in phase 1 (writer holds RowExclusiveLock)"
$P -q -c "BEGIN; INSERT INTO t VALUES (2001, 'beta', to_ftsdoc('simple', 'beta')); SELECT pg_sleep(6); COMMIT;" >/dev/null &
sleep 1
$P -q -c "CREATE INDEX CONCURRENTLY t_fts ON t USING fts (d);" &
sleep 2
$P -c "SELECT wait_event_type, wait_event, left(query,40) FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();"; chk
wait
chk
$P -q -c "DROP INDEX t_fts;"
echo "### B: CIC cancelled after indisready, before validate (a concurrent writer's row is missing)"
$P -q -c "BEGIN; INSERT INTO t VALUES (2002, 'beta', to_ftsdoc('simple', 'beta')); SELECT pg_sleep(4); COMMIT;" >/dev/null &
sleep 1
$P -q -c "CREATE INDEX CONCURRENTLY t_fts ON t USING fts (d);" &
sleep 1
$P -q -c "BEGIN; INSERT INTO t VALUES (2003, 'omega alpha', to_ftsdoc('simple', 'omega alpha')); SELECT pg_sleep(8); COMMIT;" >/dev/null &
sleep 4
$P -c "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();" -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();"
sleep 6
echo "(writer committed; 20001 alpha rows and 1 omega row are live)"
chk
$P -At -c "SELECT 'truth: alpha=' || count(*) FILTER (WHERE fts_match(d, 'alpha'::ftsquery)) || ' omega=' || count(*) FILTER (WHERE fts_match(d, 'omega'::ftsquery)) FROM t"
$P -q -c "DROP INDEX t_fts;"
echo "### C: CIC blocked in WaitForOlderSnapshots (repeatable-read reader holds a snapshot)"
$P -q -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT 1 FROM t LIMIT 1; SELECT pg_sleep(6); COMMIT;" >/dev/null &
sleep 1
$P -q -c "CREATE INDEX CONCURRENTLY t_fts ON t USING fts (d);" &
sleep 2
$P -c "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX%' AND pid <> pg_backend_pid();"; chk
wait
chk
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo CIC2_DONE
