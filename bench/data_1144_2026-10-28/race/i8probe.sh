#!/bin/bash
for L in v1143h i20h; do for M in 17; do
  B=/nvme/rm/pfx$M-$L/bin; D=/nvme/rm/d$M-$L; P=60$M
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  $B/dropdb -h /tmp -p $P -U postgres --if-exists i8 >/dev/null 2>&1; $B/createdb -h /tmp -p $P -U postgres i8
  $B/psql -X -q -h /tmp -p $P -U postgres -d i8 -c "CREATE EXTENSION pg_fts" 2>/dev/null
  echo "### PG$M $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
  $B/psql -X -q -h /tmp -p $P -U postgres -d i8 -f /tmp/rm/i8probe.sql 2>&1 | grep -v "WARNING:  pg_fts was built"
  $B/pg_ctl -D $D -w stop >/dev/null
done; done
