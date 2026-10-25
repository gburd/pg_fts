#!/bin/bash
# runcheck.sh <prefix-name> <data-name> <port>
X=$1; N=$2; P=$3
bash /tmp/pgc.sh $X $N $P start >/dev/null
PS="/nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X postgres"
echo "### $N ($X) ext $($PS -Atc "select extversion from pg_extension where extname='pg_fts'")"
$PS -c "SET enable_seqscan = off" -c "EXPLAIN (COSTS OFF) SELECT 1 FROM ag WHERE to_ftsdoc('english', message) @@@ 'vacuum'::ftsquery AND NOT fts_match(to_ftsdoc('english', message), 'vacuum'::ftsquery)" | head -8
S=$(date +%s.%N); $PS -f /tmp/check_terms.sql 2>&1; echo "check_terms $(echo "$(date +%s.%N) - $S" | bc) s"
S=$(date +%s.%N); $PS -q -f /tmp/check_full.sql 2>&1; echo "check_full $(echo "$(date +%s.%N) - $S" | bc) s"
bash /tmp/pgc.sh $X $N $P stop >/dev/null
