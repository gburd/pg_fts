#!/bin/bash
set -uo pipefail
for TAG in v130 v140 final r2a; do
  B=/nvme/b3/repro/pg-$TAG/bin; D=/nvme/b3/small-$TAG; [ -d $D ] && mv $D /nvme/trash_sm_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1; printf "port=55740\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null; $B/psql -h /tmp -p 55740 -U postgres -X -q -c "CREATE EXTENSION pg_fts"
  echo "$TAG: $($B/psql -h /tmp -p 55740 -U postgres -X -q -f /tmp/small.sql | grep -E 'Limit|Scan|actual' | sed 's/  */ /g' | tr '\n' '|')"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done
