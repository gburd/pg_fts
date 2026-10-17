#!/bin/bash
# Item 4: reporter repro.sh (mwm=4GB, doclen_sidecar=off, PG18) at 200k; round-1 build (pg-final) vs round-2 (pg-r2a), sequential.
set -uo pipefail
R=/nvme/b3/repro; cd $R
for TAG in ${TAGS:-final r2a}; do
  x=$R/data-$TAG-200000; [ -e $x ] && mv $x /nvme/trash_b1_$RANDOM
  echo "######## repro.sh $TAG 200000 so=$(md5sum $R/pg-$TAG/lib/postgresql/pg_fts.so | cut -c1-8)"; bash $R/repro.sh $R $TAG 55612 200000 2>&1 | grep -v "^initdb"
  mv $R/data-$TAG-200000 /nvme/trash_b1_$RANDOM
done
echo BUG1R2_DONE
