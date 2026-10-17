#!/bin/bash
set -uo pipefail
p=55650
for spec in fix2:18 v140:18 mutB2:18 mut32:18 fix2:17 v140:17 mutB2:17; do
  TAG=${spec%%:*}; M=${spec##*:}; p=$((p+1))
  TAG=$TAG M=$M PORT=$p TESTS="planner_pending vacuum_parallel" bash /tmp/newtests.sh > /nvme/b3/nt-$TAG-$M.log 2>&1 &
done
wait
for spec in fix2:18 v140:18 mutB2:18 mut32:18 fix2:17 v140:17 mutB2:17; do
  TAG=${spec%%:*}; M=${spec##*:}; echo "== $TAG PG$M: $(grep -E '^(ok|not ok)' /nvme/b3/nt-$TAG-$M.log | awk '{print $1,$2,$4}' | tr '\n' ';')"
done
echo NTALL_DONE
