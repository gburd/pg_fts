#!/bin/bash
# nixrep.sh: installcheck-pg17 x3 on fix1142 (1.14.2) and x3 on main (1.14.1), sequential
. ~/.nix-profile/etc/profile.d/nix.sh
for arm in fix1142:/nvme/fp/r1142full.bundle main:/nvme/fp/main.bundle; do
  BR=${arm%%:*}; B=${arm#*:}; D=/nvme/nixrep-$BR; [ -d $D ] && mv $D /nvme/trash_nr_$RANDOM
  git clone -q -b $BR $B $D && cd $D
  for i in 1 2 3; do
    nix --extra-experimental-features 'nix-command flakes' build .#checks.x86_64-linux.installcheck-pg17 -L --no-link --rebuild > /nvme/fp/gate/nixrep-$BR-$i.log 2>&1 \
      || nix --extra-experimental-features 'nix-command flakes' build .#checks.x86_64-linux.installcheck-pg17 -L --no-link > /nvme/fp/gate/nixrep-$BR-$i.log 2>&1
    rc=$?
    echo "$BR $(git log -1 --format=%h) run $i rc=$rc $(grep -E 'tests (passed|failed)' /nvme/fp/gate/nixrep-$BR-$i.log | head -1 | sed 's/.*> //') $(grep -E 'not ok' /nvme/fp/gate/nixrep-$BR-$i.log | awk '{print $5}' | tr '\n' ' ') serial_reclaims: $(grep -A4 'serial_reclaims FROM' /nvme/fp/gate/nixrep-$BR-$i.log | grep -E '^\S+> [-+]? *[tf]$' | tr '\n' ' ')"
  done
done
echo NIXREP_DONE
