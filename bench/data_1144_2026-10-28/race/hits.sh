#!/bin/bash
# build rd (first part of ranked_driven_and.sql up to VACUUM ANALYZE) and print buffer hits, 1.14.3 vs i19, PG17
for L in v1143 i19; do
  B=/nvme/rm/pfx17-$L/bin; D=/nvme/rm/d17-$L; P=6117; [ $L = i19 ] && P=6217
  if [ $L = v1143 ]; then T=/nvme/rm/src-v1143; cd $T; make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1; fi
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  $B/dropdb -h /tmp -p $P -U postgres --if-exists h >/dev/null 2>&1; $B/createdb -h /tmp -p $P -U postgres h
  sed -n '1,/^VACUUM ANALYZE rd;/p' /nvme/rm/src-i19/sql/ranked_driven_and.sql | $B/psql -X -q -h /tmp -p $P -U postgres -d h >/dev/null 2>&1
  echo "### PG17 $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) nseg=$($B/psql -X -At -h /tmp -p $P -U postgres -d h -c "SELECT fts_index_nsegments('rd_fts')")"
  $B/psql -X -q -h /tmp -p $P -U postgres -d h -f /tmp/rm/hits.sql
  $B/pg_ctl -D $D -w stop >/dev/null
done
