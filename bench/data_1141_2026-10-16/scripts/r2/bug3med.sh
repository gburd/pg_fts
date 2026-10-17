#!/bin/bash
# Item 8: bug-3 LIMIT 20 latency, median of 7 EXPLAIN ANALYZE in one session after 2 discarded; v140 vs r2a, PG 18.6.
set -uo pipefail
R=/nvme/b3/repro; PORT=55602
for TAG in v140 r2a; do
  B=$R/pg-$TAG/bin; D=/nvme/b3/bug3m-$TAG
  $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_b3_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\npg_fts.pending_flush_threshold=0\nshared_buffers=1GB\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
  $P -c "CREATE EXTENSION pg_fts"; $P -v rows=100000 -v pend=3000 -f /tmp/bug3.sql >/dev/null
  { echo "SET client_min_messages = warning;"; for i in 1 2 3 4 5 6 7 8 9; do echo "EXPLAIN (ANALYZE, SUMMARY ON) SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery LIMIT 20;"; done; } > /nvme/b3/b3m.sql
  $P -f /nvme/b3/b3m.sql > /nvme/b3/b3m-$TAG.out
  echo "$TAG so=$(md5sum $R/pg-$TAG/lib/postgresql/pg_fts.so | cut -c1-8) plan: $(grep -m1 -oE 'Seq Scan|Bitmap Heap Scan|Index Scan' /nvme/b3/b3m-$TAG.out) rows: $(grep -m1 -oE 'rows=[0-9]+' /nvme/b3/b3m-$TAG.out | head -1); exec ms (7 after 2 warm): $(sed -n 's/^Execution Time: \([0-9.]*\) ms/\1/p' /nvme/b3/b3m-$TAG.out | tail -7 | tr '\n' ' ') median $(sed -n 's/^Execution Time: \([0-9.]*\) ms/\1/p' /nvme/b3/b3m-$TAG.out | tail -7 | sort -n | sed -n 4p)"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done
echo BUG3MED_DONE
