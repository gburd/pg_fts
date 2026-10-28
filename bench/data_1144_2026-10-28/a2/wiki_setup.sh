#!/bin/bash
# wiki cluster on PG 17.10 (/nvme/rm/pfx17-wk = copy of /nvme/pg17), stored ftsdoc column + default fts index,
# settings of the 1.11.0 protocol scaled to this 61 GB host.  The build .so is the CURRENT tree (A2 is a query
# change; both arms read the same index).  Log: /nvme/rm/wiki_setup.log
set -uo pipefail
exec > /nvme/rm/wiki_setup.log 2>&1
PFX=/nvme/rm/pfx17-wk; [ -d $PFX ] || cp -a /nvme/pg17 $PFX; B=$PFX/bin
T=/nvme/rm/src-wk; [ -d $T ] && mv $T /nvme/trash_wk_$RANDOM; mkdir -p $T; tar xzf /nvme/rm/i17.tgz -C $T; cd $T
make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1 || { echo BUILD_FAIL; exit 1; }
echo "so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) tree $(cat GITREV)"
D=/nvme/rm/dwk; [ -d $D ] && { $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; mv $D /nvme/trash_wk_$RANDOM; }
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null
cat >> $D/postgresql.conf <<C
port=6317
unix_socket_directories='/tmp'
listen_addresses=''
shared_buffers=16GB
work_mem=256MB
maintenance_work_mem=8GB
max_parallel_maintenance_workers=8
jit=off
autovacuum=off
max_connections=50
default_text_search_config='english'
C
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -X -q -h /tmp -p 6317 -U postgres"
$P -c "CREATE TABLE docs(id bigint PRIMARY KEY, content text)" -c "\\copy docs FROM '/nvme/c.tsv' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\b')" -c "CREATE EXTENSION pg_fts" -c "CREATE EXTENSION pg_prewarm"
echo "rows $($P -At -c 'select count(*) from docs')"
s=$(date +%s); $P -c "ALTER TABLE docs ADD COLUMN d ftsdoc" -c "UPDATE docs SET d = to_ftsdoc('english', content)" -c "VACUUM (FREEZE, ANALYZE) docs"; echo "column fill s=$(( $(date +%s)-s ))"
s=$(date +%s); $P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_fts ON docs USING fts (d)"; echo "index build s=$(( $(date +%s)-s ))"
$P -c "VACUUM ANALYZE docs"
echo "index size $($P -At -c "select pg_size_pretty(pg_relation_size('docs_fts'))") nseg $($P -At -c "select fts_index_nsegments('docs_fts')")"
$B/pg_ctl -D $D -w stop >/dev/null
echo WIKI_SETUP_DONE
