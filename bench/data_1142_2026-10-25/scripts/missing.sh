#!/bin/bash
# run the CHANGELOG step-2 check on C1 (1.10.0 -> 1.14.1 upgraded) and A (1.14.1 from start)
for spec in "pg18-upgC C1 5492" "pg18-v1141 A 5490"; do
  set -- $spec; X=$1; N=$2; P=$3
  [ -x /nvme/fp/$X/bin/psql ] || { echo "### $N: prefix /nvme/fp/$X missing"; ls -d /nvme/fp/pg18* ; continue; }
  bash /tmp/pgc.sh $X $N $P start >/dev/null 2>&1
  PS="/nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X postgres"
  echo "### $N ($X) ext $($PS -Atc "select extversion from pg_extension where extname='pg_fts'")"
  $PS -f /tmp/missing.sql 2>&1 | grep -vE '^$'
  bash /tmp/pgc.sh $X $N $P stop >/dev/null 2>&1
done
echo MISSING_DONE
