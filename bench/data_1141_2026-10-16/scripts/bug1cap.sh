#!/bin/bash
# Bug 1 batch cap: reporter's repro.sh (mwm=4GB, sidecar off, PG18) per variant, sequential.
set -uo pipefail
R=/nvme/b3/repro; cd $R
for spec in ${SPECS:-200000:v140 200000:fix 200000:cap1m 200000:cap8m 200000:cap16m 400000:v130 400000:v140 400000:fix 400000:cap1m 400000:cap8m}; do
  ROWS=${spec%%:*}; TAG=${spec##*:}
  for x in $R/data-$TAG-$ROWS $R/data-onerow-$TAG; do [ -e $x ] && mv $x /nvme/trash_b1_$RANDOM; done
  echo "######## repro.sh $TAG $ROWS"; bash $R/repro.sh $R $TAG 55612 $ROWS 2>&1 | grep -v "^initdb"
  mv $R/data-$TAG-$ROWS /nvme/trash_b1_$RANDOM
done
for TAG in fix cap1m; do echo "######## onerow $TAG"; bash $R/repro-onerow.sh $R $TAG 55611 200000 2>&1; mv $R/data-onerow-$TAG /nvme/trash_b1_$RANDOM; done
echo BUG1CAP_DONE
