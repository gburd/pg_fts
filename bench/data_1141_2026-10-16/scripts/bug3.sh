#!/bin/bash
# Bug 3: fts_matchsel with a non-empty pending list, PG18, per tag.  ROWS PEND as env.
set -uo pipefail
R=/nvme/b3/repro; ROWS=${ROWS:-100000}; PEND=${PEND:-3000}; PORT=55601
for TAG in ${TAGS:-v130 v140 fix}; do
  B=$R/pg-$TAG/bin; D=/nvme/b3/bug3-$TAG
  $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_b3_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\npg_fts.pending_flush_threshold=0\nshared_buffers=1GB\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
  echo "===== $TAG rows=$ROWS pending=$PEND"
  $P -c "CREATE EXTENSION pg_fts"
  $P -v rows=$ROWS -v pend=$PEND -f /tmp/bug3.sql
  echo "--- timing ($TAG)"; $P -f /tmp/bug3time.sql | grep -E "Execution Time|Scan|Custom|rows=" | head -20
  echo "--- after fts_merge ($TAG): npending -> 0"
  $P -c "SELECT fts_merge('docs_fts') IS NOT NULL" -c "SELECT 'npending='||meta_u32(60)" -c "SELECT est('rare')" -c "SELECT est('rar*')"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done
echo BUG3_DONE
