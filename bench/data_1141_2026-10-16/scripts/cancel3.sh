#!/bin/bash
# What happens between the cancel ERROR and the victim leaving state=active?  Reporter's cancel step
# (5% delete, cancel 2s into "vacuuming indexes"), polling pg_stat_activity with timestamps.
set -uo pipefail
R=/nvme/b3/repro; TAG=${TAG:-fix2}; ROWS=${ROWS:-400000}; PORT=55740; B=$R/pg-$TAG/bin; D=/nvme/b3/c3-$TAG-$ROWS
$B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_c_$RANDOM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
$B/pg_ctl -D $D -l $D/log -w start -o "-k /tmp -p $PORT -c listen_addresses='' -c shared_buffers=128MB -c maintenance_work_mem=4GB -c autovacuum=off -c max_parallel_maintenance_workers=0 -c log_disconnections=on -c log_line_prefix='%m [%p] %a '" >/dev/null
P() { $B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE docs (id int PRIMARY KEY, body text)" \
  -c "INSERT INTO docs SELECT g, (SELECT string_agg('w'||(random()*2e6)::int, ' ') FROM generate_series(1,300) WHERE g>0) FROM generate_series(1,$ROWS) g"
P -c "CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('english', body)) WITH (doclen_sidecar=off)" 2>/dev/null
P -c "VACUUM (FREEZE) docs"
for k in 0 1; do
  P -c "DELETE FROM docs WHERE id % 20 = $k"
  PGAPPNAME=victim $B/psql -h /tmp -p $PORT -U postgres -X -q -c "VACUUM docs" 2>&1 | sed 's/^/  victim: /' &
  for i in $(seq 1 400); do ph=$(P -c "SELECT phase FROM pg_stat_progress_vacuum p JOIN pg_stat_activity a USING (pid) WHERE a.application_name='victim'"); [ "$ph" = "vacuuming indexes" ] && break; sleep 0.05; done
  sleep 2
  c0=$(date +%s.%N); P -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name='victim'" >/dev/null
  while :; do
    st=$(P -c "SELECT state||'/'||coalesce(wait_event_type,'-')||':'||coalesce(wait_event,'-')||'/'||coalesce((SELECT phase FROM pg_stat_progress_vacuum v WHERE v.pid=a.pid),'noprogress') FROM pg_stat_activity a WHERE application_name='victim'")
    echo "  +$(printf %.2f $(echo "$(date +%s.%N) - $c0" | bc))s ${st:-gone}"
    [ -z "$st" ] && break; [[ "$st" != active* ]] && break
    sleep 0.05
  done | awk '{k=$2; if (k!=prev) print; prev=k}'
  wait
done
grep -E "canceling|disconnection.*victim|victim.*disconnection" $D/log | cut -c1-160
$B/pg_ctl -D $D -m fast -w stop >/dev/null
echo CANCEL3_DONE
