#!/bin/bash
for L in v1143h i20h; do
  B=/nvme/rm/pfx17-$L/bin; D=/nvme/rm/d17-$L; P=6017
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  $B/dropdb -h /tmp -p $P -U postgres --if-exists i8 >/dev/null 2>&1; $B/createdb -h /tmp -p $P -U postgres i8
  $B/psql -X -q -h /tmp -p $P -U postgres -d i8 -c "CREATE EXTENSION pg_fts" 2>/dev/null
  echo "### PG17 $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
  $B/psql -X -q -h /tmp -p $P -U postgres -d i8 -f /tmp/rm/i8scale.sql 2>&1 | grep -v "WARNING:  pg_fts was built" | tail -9
  $B/pg_ctl -D $D -w stop >/dev/null
done
