#!/bin/bash
# Index growth when cleanup's compaction runs but truncation is declined.
# C: CIC (front-free layout, native).  D: sql/vacuum_parallel layout.  E: serial VACUUM while a
# reader holds AccessShareLock on the index (ConditionalLockRelation AEL fails).
set -uo pipefail
R=/nvme/b3/repro; PORT=55625
TAG=${TAG:-v140}
B=$R/pg-$TAG/bin
sz() { $P -c "select pg_relation_size('m_fts')/8192"; }
fresh() {
  D=/nvme/b3/bug2e-$TAG-$1
  $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_b2_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\nmax_parallel_maintenance_workers=4\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
}
chk() { echo "idx=$($P -c "set enable_seqscan=off; select count(*) from m where to_ftsdoc('english',body) @@@ 'w30'::ftsquery") heap=$($P -c "select count(*) from m where fts_match(to_ftsdoc('english',body),'w30'::ftsquery)")"; }
# C
fresh C
sed "s/^CREATE INDEX m_fts ON m/ALTER TABLE m SET (parallel_workers = 4); CREATE INDEX CONCURRENTLY m_fts ON m/; s/generate_series(1, 20000) g/generate_series(1, 60000) g/" /tmp/bug2_load.sql > /tmp/bug2e_load.sql
$P -f /tmp/bug2e_load.sql >/dev/null
line="[C $TAG CIC] nseg $($P -c "select fts_index_nsegments('m_fts')") start $(sz)"
for i in 1 2 3; do $P -c "DELETE FROM m WHERE id % 97 = $i" >/dev/null; e=$($P -c 'VACUUM m' 2>&1 | grep -c ERROR); line="$line | par#$i $(sz)$([ $e -gt 0 ] && echo '(ERR)')"; done
$P -c "DELETE FROM m WHERE id % 97 = 9" >/dev/null; $P -c 'VACUUM (PARALLEL 0) m' >/dev/null 2>&1; line="$line | serial $(sz)"
echo "$line | $(chk)"
$B/pg_ctl -D $D -m fast -w stop >/dev/null
# D
fresh D
cat > /tmp/bug2e_d.sql <<'EOSQL'
SET client_min_messages = warning;
CREATE EXTENSION pg_fts;
CREATE TABLE m (id int PRIMARY KEY, body text, a int, b text);
INSERT INTO m SELECT g, (SELECT string_agg('w' || ((g + i * 13) % 6000), ' ') FROM generate_series(1, 80) i), g % 1000, md5(g::text) FROM generate_series(1, 150000) g;
CREATE INDEX m_fts ON m USING fts (to_ftsdoc('english', body));
CREATE INDEX m_b ON m (b);
CREATE INDEX m_ab ON m (a, b);
DELETE FROM m WHERE id > 30000;
SELECT fts_merge('m_fts') IS NOT NULL;
EOSQL
$P -f /tmp/bug2e_d.sql >/dev/null
line="[D $TAG vacuum_parallel layout] start $(sz)"
for i in 1 2 3; do $P -c "DELETE FROM m WHERE id % 97 = $i" >/dev/null; e=$($P -c 'SET min_parallel_index_scan_size = 0' -c 'VACUUM (PARALLEL 2) m' 2>&1 | grep -c ERROR); line="$line | par#$i $(sz)$([ $e -gt 0 ] && echo '(ERR)')"; done
$P -c "DELETE FROM m WHERE id % 97 = 9" >/dev/null; $P -c 'VACUUM (PARALLEL 0) m' >/dev/null 2>&1; line="$line | serial $(sz)"
echo "$line | $(chk)"
$B/pg_ctl -D $D -m fast -w stop >/dev/null
# E: CIC layout, serial VACUUM with a concurrent reader holding the index lock
fresh E
$P -f /tmp/bug2e_load.sql >/dev/null
line="[E $TAG CIC + reader] start $(sz)"
for i in 1 2 3; do
  $P -c "DELETE FROM m WHERE id % 97 = $i" >/dev/null
  $P -c "BEGIN" -c "SET enable_seqscan=off" -c "SELECT count(*) FROM m WHERE to_ftsdoc('english',body) @@@ 'w30'::ftsquery" -c "SELECT pg_sleep(20)" -c "COMMIT" >/dev/null &
  sleep 1
  e=$($P -c 'VACUUM (PARALLEL 0) m' 2>&1 | grep -c ERROR); line="$line | serial+reader#$i $(sz)$([ $e -gt 0 ] && echo '(ERR)')"
  wait
done
$P -c "DELETE FROM m WHERE id % 97 = 9" >/dev/null; $P -c 'VACUUM (PARALLEL 0) m' >/dev/null 2>&1; line="$line | serial-alone $(sz)"
echo "$line | $(chk)"
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo BUG2E_DONE
