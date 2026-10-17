#!/bin/bash
# Cancel latency without instrumentation: time from pg_cancel_backend() to the victim psql exiting
# with the cancel error, at several offsets into "vacuuming indexes".  Also one uncancelled
# bulkdelete VACUUM (time + VmHWM).  PG18, sidecar off, mwm=4GB (reporter's settings).
set -uo pipefail
R=/nvme/b3/repro; TAG=$1; ROWS=$2; PORT=$3; B=$R/pg-$TAG/bin; D=/nvme/b3/c2-$TAG-$ROWS
$B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_c_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
$B/pg_ctl -D $D -l $D/log -w start -o "-k /tmp -p $PORT -c listen_addresses='' -c shared_buffers=128MB -c maintenance_work_mem=4GB -c autovacuum=off -c max_parallel_maintenance_workers=0" >/dev/null
P() { $B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE docs (id int PRIMARY KEY, body text)" \
  -c "INSERT INTO docs SELECT g, (SELECT string_agg('w'||(random()*2e6)::int, ' ') FROM generate_series(1,300) WHERE g>0) FROM generate_series(1,$ROWS) g"
P -c "CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('english', body)) WITH (doclen_sidecar=off)" 2>/dev/null
P -c "VACUUM (FREEZE) docs"
P -c "DELETE FROM docs WHERE id % 20 = 0"
t0=$(date +%s.%N)
hw=$(P -c "SET client_min_messages=warning" -c "VACUUM docs" -c "SELECT (regexp_match(pg_read_file('/proc/'||pg_backend_pid()||'/status'), 'VmHWM:\s+(\d+)'))[1]::bigint/1024")
el=$(echo "$(date +%s.%N) - $t0" | bc)
lat=""; k=0
for off in 1 2 3 4 5 2 2 2; do
  k=$((k+1)); P -c "DELETE FROM docs WHERE id % 97 = $k"
  PGAPPNAME=victim $B/psql -h /tmp -p $PORT -U postgres -X -q -c "VACUUM docs" > /nvme/b3/c2-$TAG-$ROWS.victim 2>&1 &
  vp=$!
  for i in $(seq 1 600); do ph=$(P -c "SELECT phase FROM pg_stat_progress_vacuum p JOIN pg_stat_activity a USING (pid) WHERE a.application_name='victim'"); [ "$ph" = "vacuuming indexes" ] && break; sleep 0.02; done
  sleep $off
  pid=$(P -c "SELECT pid FROM pg_stat_activity WHERE application_name='victim'")
  c0=$(date +%s.%N); kill -INT $pid 2>/dev/null || true   # SIGINT to the backend = pg_cancel_backend
  wait $vp; c1=$(date +%s.%N)
  grep -q "canceling statement" /nvme/b3/c2-$TAG-$ROWS.victim && r=$(printf %.2f $(echo "$c1 - $c0" | bc)) || r="(finished)"
  lat="$lat $r"
done
echo "$TAG rows=$ROWS index=$(P -c "select pg_size_pretty(pg_relation_size('docs_fts'))") bulkdelete-VACUUM ${el%???????}s VmHWM ${hw}MB | cancel latency s:$lat"
$B/pg_ctl -D $D -m fast -w stop >/dev/null
