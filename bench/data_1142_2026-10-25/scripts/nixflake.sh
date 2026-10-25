#!/bin/bash
# nixflake.sh: installcheck-pg17 (--rebuild) alternating main (1.14.1) and fix1142 (1.14.2), N rounds,
# with a 32-way CPU burner running (the failing nixgate2 run overlapped a from-source PostgreSQL build)
. ~/.nix-profile/etc/profile.d/nix.sh
N=${N:-5}
for i in $(seq 1 32); do ( end=$(( $(date +%s) + 3600 )); while [ $(date +%s) -lt $end ] && [ ! -f /nvme/fp/gate/stopburn ]; do sha256sum /nvme/fp/commits.tsv >/dev/null; done ) & done
for r in $(seq 1 $N); do
  for BR in main fix1142; do
    cd /nvme/nixrep-$BR
    nix --extra-experimental-features 'nix-command flakes' build .#checks.x86_64-linux.installcheck-pg17 -L --no-link --rebuild > /nvme/fp/gate/nixflake-$BR-$r.log 2>&1; rc=$?
    echo "round $r $BR $(git log -1 --format=%h) rc=$rc $(grep -E 'tests (passed|failed)' /nvme/fp/gate/nixflake-$BR-$r.log | head -1 | sed 's/.*> //') notok: $(grep -E '> not ok' /nvme/fp/gate/nixflake-$BR-$r.log | awk '{print $5}' | tr '\n' ' ') load $(cut -d' ' -f1 /proc/loadavg)"
  done
done
touch /nvme/fp/gate/stopburn; wait
echo NIXFLAKE_DONE
