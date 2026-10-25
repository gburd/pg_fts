#!/bin/bash
# runt.sh <prefix-name> <port> <sqlfile> : fresh cluster, CREATE EXTENSION, run file, print output
X=$1; P=$2; F=$3; N=t-$X
bash /tmp/pgc.sh $X $N $P init >/dev/null; sed -i 's/^shared_buffers = 4GB/shared_buffers = 256MB/' /nvme/fp/d-$N/postgresql.conf
bash /tmp/pgc.sh $X $N $P start >/dev/null
PS="/nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X postgres"
$PS -q -c 'CREATE EXTENSION pg_fts'
echo "### $X $($PS -Atc "select extversion from pg_extension where extname='pg_fts'")"
$PS -a -f $F 2>&1
bash /tmp/pgc.sh $X $N $P stop >/dev/null
