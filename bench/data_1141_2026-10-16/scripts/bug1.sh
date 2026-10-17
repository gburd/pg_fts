#!/bin/bash
# Bug 1: reporter's own harness, PG18, 200k rows, doclen_sidecar=off. Sequential (clean RSS).
set -uo pipefail
R=/nvme/b3/repro; ROWS=${ROWS:-200000}; cd $R
for TAG in ${TAGS:-v130 v140 fix}; do
  for x in $R/data-onerow-$TAG $R/data-$TAG-$ROWS; do [ -e $x ] && mv $x /nvme/trash_b1_$RANDOM; done
  echo "######## onerow $TAG"; bash $R/repro-onerow.sh $R $TAG 55611 $ROWS 2>&1
  echo "######## repro.sh $TAG"; bash $R/repro.sh $R $TAG 55612 $ROWS 2>&1
done
echo BUG1_DONE
