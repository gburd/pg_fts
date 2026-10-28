#!/bin/bash
# a2lat.sh <label> <so path>: install the given pg_fts.so into the wiki prefix, start the cluster, 3 runs of a2lat.sql
L=$1; SO=$2; B=/nvme/rm/pfx17-wk/bin; D=/nvme/rm/dwk; O=/nvme/rm/a2; mkdir -p $O
cp $SO $($B/pg_config --pkglibdir)/pg_fts.so
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
echo "== $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
for r in 1 2 3; do $B/psql -X -h /tmp -p 6317 -U postgres -f /tmp/rm/a2lat.sql > $O/lat_${L}_$r.out 2>&1; done
$B/pg_ctl -D $D -w stop >/dev/null
