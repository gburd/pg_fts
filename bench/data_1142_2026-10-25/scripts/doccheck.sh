#!/bin/bash
# the CHANGELOG 1.14.2 check queries exactly as printed (t=ag, body=message), on C1 (corrupt) and A (clean)
for spec in "pg18-upgC C1 5492" "pg18-v1141 A 5490"; do
  set -- $spec; X=$1; N=$2; P=$3
  bash /tmp/pgc.sh $X $N $P start >/dev/null 2>&1
  PS="/nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X postgres"
  echo "### $N ($X) ext $($PS -Atc "select extversion from pg_extension where extname='pg_fts'")"
  echo "--- plan of check 1 (one term)"; $PS -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "EXPLAIN (COSTS OFF) SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','vacuum') AND NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','vacuum'))"
  echo "--- check 1"; $PS -f /tmp/doc_check1.sql 2>&1 | grep -vE '^$'
  echo "--- check 2"; $PS -f /tmp/doc_check2.sql 2>&1 | grep -vE '^$'
  bash /tmp/pgc.sh $X $N $P stop >/dev/null 2>&1
done
echo DOCCHECK_DONE
