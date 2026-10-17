#!/bin/bash
# Sequential bulkdelete timing per batch cap on ONE 400k-doc sidecar-off index (PG 18.6): the same
# data dir is restarted under each variant's prefix (same server build, different pg_fts.so).
# VACUUM (INDEX_CLEANUP ON) after a small delete; \timing in-session; VmHWM of that backend.
set -uo pipefail
R=/nvme/b3/repro; ROWS=${ROWS:-400000}; PORT=55720
PFX=$R/pg-cap256k; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
S=/nvme/b3/src-cap256k; [ -d $S ] && mv $S /nvme/trash_src_$RANDOM; mkdir -p $S; tar xzf /nvme/b3/fix.tgz -C $S; cd $S
make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$PFX/bin/pg_config COPT="-DBM25_BULKDELETE_BATCH_MAX=262144" 2>&1 | grep error; make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
D=/nvme/b3/captime-$ROWS; B=$R/pg-fix2/bin
$B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_ct_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=128MB\nmaintenance_work_mem=4GB\nautovacuum=off\nmax_parallel_maintenance_workers=0\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P() { $B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE docs (id int PRIMARY KEY, body text)" \
  -c "INSERT INTO docs SELECT g, (SELECT string_agg('w'||(random()*2e6)::int, ' ') FROM generate_series(1,300) WHERE g>0) FROM generate_series(1,$ROWS) g"
P -c "CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('english', body)) WITH (doclen_sidecar=off)" 2>/dev/null
P -c "VACUUM (FREEZE) docs"
$B/pg_ctl -D $D -w stop >/dev/null
k=0
for rep in 1 2 3; do for v in cap256k cap1m fix2 cap8m; do
  k=$((k+1)); B=$R/pg-$v/bin
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  P() { $B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
  P -c "DELETE FROM docs WHERE id % 1009 = $k" -c "CHECKPOINT"
  out=$(printf '%s\n' "SET client_min_messages=warning;" "\\timing on" "VACUUM (INDEX_CLEANUP ON) docs;" "\\timing off" \
    "SELECT 'hwm=' || (regexp_match(pg_read_file('/proc/'||pg_backend_pid()||'/status'), 'VmHWM:\s+(\d+)'))[1]::bigint/1024;" | P 2>&1 | grep -E "Time:|hwm=" | tr '\n' ' ')
  echo "rep$rep $v: $out"
  $B/pg_ctl -D $D -w stop >/dev/null
done; done
echo "segments: $(P -c 'select 1' >/dev/null 2>&1; echo n/a)"
echo CAPTIME_DONE
