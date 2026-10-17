#!/bin/bash
# Cancel latency, measured repeatedly on ONE 400k-doc sidecar-off index (PG18, TAG), at several offsets
# into "vacuuming indexes"; gdb samples of the backend between cancel and exit.
set -uo pipefail
R=/nvme/b3/repro; TAG=${TAG:-fix}; ROWS=${ROWS:-400000}; PORT=${PORT:-55641}; B=$R/pg-$TAG/bin; D=/nvme/b3/cancel-$TAG-$ROWS
$B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_c_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
$B/pg_ctl -D $D -l $D/log -w start -o "-k /tmp -p $PORT -c listen_addresses='' -c shared_buffers=128MB -c maintenance_work_mem=4GB -c autovacuum=off -c max_parallel_maintenance_workers=0" >/dev/null
P() { $B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE docs (id int PRIMARY KEY, body text)" \
  -c "INSERT INTO docs SELECT g, (SELECT string_agg('w'||(random()*2e6)::int, ' ') FROM generate_series(1,300) WHERE g>0) FROM generate_series(1,$ROWS) g"
P -c "CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('english', body)) WITH (doclen_sidecar=off)" 2>/dev/null
P -c "VACUUM (FREEZE) docs"
echo "== $TAG $ROWS: index $(P -c "select pg_size_pretty(pg_relation_size('docs_fts'))")"
k=0
for off in 0.5 1 2 3 4 5 6 2 2; do
  k=$((k+1)); P -c "DELETE FROM docs WHERE id % 97 = $k"
  PGAPPNAME=victim $B/psql -h /tmp -p $PORT -U postgres -X -q -c "VACUUM docs" >/dev/null 2>&1 &
  for i in $(seq 1 400); do ph=$(P -c "SELECT phase FROM pg_stat_progress_vacuum p JOIN pg_stat_activity a USING (pid) WHERE a.application_name='victim'"); [ "$ph" = "vacuuming indexes" ] && break; sleep 0.05; done
  t_ix=$(date +%s.%N); sleep $off
  pid=$(P -c "SELECT pid FROM pg_stat_activity WHERE application_name='victim'")
  c0=$(date +%s.%N); P -c "SELECT pg_cancel_backend($pid)" >/dev/null
  samples=""
  while kill -0 $pid 2>/dev/null && [ -n "$(P -c "SELECT 1 FROM pg_stat_activity WHERE pid=$pid AND state='active'")" ]; do
    f=$(sudo gdb -p $pid -batch -ex bt 2>/dev/null | grep -E "^#[0-9]" | grep -oE "in [a-z_0-9]+ " | head -6 | awk '{print $2}' | tr '\n' '<'); samples="$samples [$f]"; sleep 0.1
  done
  c1=$(date +%s.%N); wait
  echo "offset ${off}s: cancel latency $(printf %.2f $(echo "$c1 - $c0" | bc))s; samples:$samples" | cut -c1-900
done
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo CANCEL_DONE
