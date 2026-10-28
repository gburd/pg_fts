#!/bin/bash
# final gate for 1.14.3 tree 60aa460: main gate (incl. t/013) -> upgrade -> ASan -> per-commit (9 code commits)
# -> nix flake (4 checks) + 2 --rebuild reruns of installcheck-pg17.  Every stage asserts green; logs of earlier runs
# are moved to r2/.
G=/nvme/iss/gate; mkdir -p $G/r2
mv -f $G/gate143.log $G/upg143.log $G/asan143.log $G/asan_step.log $G/percommit143.log $G/nix143b.log $G/all143b.out $G/tap17.log $G/tap18.log $G/fuzz.log $G/ic17.log $G/ic18.log $G/pc-*.log $G/nixrep17-*.log $G/r2/ 2>/dev/null
for c in $(cat /tmp/g/commits.txt); do [ -d $G/pc-$c ] && mv $G/pc-$c /nvme/trash_pcp_$RANDOM; done
echo "tree $(tar xzf $G/final.tgz -O GITREV); commits: $(cat /tmp/g/commits.txt)"
bash /tmp/g/gate143.sh; echo "gate rc=$? $(grep -E 'installcheck rc|tap rc|check-alloc|check-ascii|fuzz rc|ALL CLEAN' $G/gate143.log | tr '\n' ' ')"
bash /tmp/g/upg143.sh; echo "upg rc=$? $(grep -c 'UPGRADE OK' $G/upg143.log) UPGRADE OK"
bash /tmp/g/asan143.sh; echo "asan rc=$?"
COMMITS="$(cat /tmp/g/commits.txt)" bash /tmp/g/percommit143.sh; echo "percommit rc=$?"
bash /tmp/g/nixgate143.sh $G/fix1143.bundle final3 > $G/nix143c.log 2>&1; echo "nix rc=$? $(grep -E '^nix build rc' $G/nix143c.log)"
. ~/.nix-profile/etc/profile.d/nix.sh
cd /nvme/nixgate-final3 && echo "nix tree $(git log -1 --format=%h)"
for i in 1 2; do
  nix --extra-experimental-features 'nix-command flakes' build .#checks.x86_64-linux.installcheck-pg17 -L --no-link --rebuild > $G/nixrep17-$i.log 2>&1
  echo "nix pg17 rerun $i rc=$? $(grep -E 'tests (passed|failed)' $G/nixrep17-$i.log | sed 's/.*> //' | tr '\n' ' ')"
done
echo ALL143C_DONE
