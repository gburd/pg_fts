#!/bin/bash
# full 1.14.3 gate on iss for tree 8079e2b: main gate -> upgrade -> ASan smoke -> per-commit -> nix install + flake checks
G=/nvme/iss/gate
bash /tmp/g/gate143.sh; echo "gate rc=$?"
bash /tmp/g/upg143.sh; echo "upg rc=$?"
bash /tmp/g/asan143.sh; echo "asan rc=$?"
COMMITS="$(cat /tmp/g/commits.txt)" bash /tmp/g/percommit143.sh; echo "percommit rc=$?"
bash /tmp/g/nixinst.sh > $G/nixinst.log 2>&1; echo "nixinst rc=$?"
bash /tmp/g/nixgate143.sh $G/fix1143.bundle final > $G/nix143.log 2>&1; echo "nix rc=$?"
echo ALL143_DONE
