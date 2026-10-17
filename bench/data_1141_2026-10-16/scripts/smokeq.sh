#!/bin/bash
for TAG in fix2 v140; do
P=/nvme/b3/repro/pg-$TAG/bin; D=/nvme/b3/smq-$TAG; $P/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_sq_$RANDOM
$P/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55790\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
$P/pg_ctl -D $D -l $D/log -w start >/dev/null
echo "== $TAG"; $P/psql -h /tmp -p 55790 -U postgres -X -q -c "CREATE EXTENSION pg_fts" -f /tmp/smokeq.sql
$P/pg_ctl -D $D -w stop >/dev/null
done
