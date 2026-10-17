#!/bin/bash
# 600k CIC build: fts size right after CIC, after VACUUM ANALYZE #1 and #2 (no reader, serial), per arm.
set -uo pipefail
TAG=$1; PORT=$2; R=/nvme/b3/repro; B=$R/pg-$TAG/bin
D=/nvme/b3/scale2-$TAG; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_sc_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\nshared_buffers=2GB\nmaintenance_work_mem=256MB\nmax_parallel_maintenance_workers=4\nmax_worker_processes=16\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE m (id int PRIMARY KEY, body text, a int, b text)" \
   -c "INSERT INTO m SELECT g, (SELECT string_agg('w' || ((g * 7 + i * 13) % 50000), ' ') FROM generate_series(1, 30) i), g % 1000, md5(g::text) FROM generate_series(1, 600000) g" \
   -c "ALTER TABLE m SET (parallel_workers = 4)" -c "CREATE INDEX CONCURRENTLY m_fts ON m USING fts (to_ftsdoc('simple', body))" \
   -c "CREATE INDEX m_b ON m (b)" -c "CREATE INDEX m_ab ON m (a, b)" >/dev/null
sz() { $P -c "select pg_relation_size('m_fts')/8192"; }
line="[$TAG] after CIC $(sz) nseg $($P -c "select fts_index_nsegments('m_fts')")"
$P -c "VACUUM (ANALYZE, PARALLEL 0) m"; line="$line | VACUUM#1 $(sz)"
$P -c "VACUUM (PARALLEL 0) m"; line="$line | VACUUM#2 $(sz)"
$P -c "DELETE FROM m WHERE id % 97 = 1" -c "VACUUM (PARALLEL 0) m"; line="$line | del+VACUUM#3 $(sz)"
$P -c "SELECT fts_vacuum('m_fts')" >/dev/null; line="$line | fts_vacuum $(sz)"
echo "$line | idx=$($P -c "set enable_seqscan=off; select count(*) from m where to_ftsdoc('simple',body) @@@ 'w30'::ftsquery") heap=$($P -c "select count(*) from m where fts_match(to_ftsdoc('simple',body),'w30'::ftsquery)")"
$B/pg_ctl -D $D -m fast -w stop >/dev/null
