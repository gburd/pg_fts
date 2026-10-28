#!/bin/bash
# run1142.sh <sqlfile> : run on both v1.14.2 clusters, fresh db each
for M in 17 18; do
  P=/nvme/iss/pg$M-v1142/bin
  $P/dropdb -h /tmp -p 57$M -U postgres --if-exists r >/dev/null 2>&1; $P/createdb -h /tmp -p 57$M -U postgres r
  echo "##### PG$M v1.14.2 $1"; $P/psql -X -h /tmp -p 57$M -U postgres -d r -f $1 2>&1
done
