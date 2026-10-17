#!/bin/bash
# reporter's repro.sh unchanged except: server logs every statement with ms timestamps, so the cancel
# (pg_cancel_backend statement) and the victim's "canceling statement" error can be timed server-side.
set -uo pipefail
R=/nvme/b3/repro; TAG=${TAG:-fix2}; ROWS=${ROWS:-400000}
sed "s/-c max_parallel_maintenance_workers=0\"/-c max_parallel_maintenance_workers=0 -c log_min_duration_statement=0 -c log_line_prefix='%m [%p] %a '\"/" $R/repro.sh > /tmp/repro_ts.sh
grep -c log_min_duration /tmp/repro_ts.sh
[ -e $R/data-$TAG-$ROWS ] && mv $R/data-$TAG-$ROWS /nvme/trash_ts_$RANDOM
cp $R/postings_all.py /nvme/b3/repro/ 2>/dev/null
bash /tmp/repro_ts.sh $R $TAG 55730 $ROWS 2>&1 | grep -v ^initdb
L=$R/server-$TAG-$ROWS.log
grep -E "pg_cancel_backend|canceling statement|victim.*duration" $L | cut -c1-200
echo CANCELTS_DONE
