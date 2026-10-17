#!/bin/bash
# nixgate.sh <bundle> <tag>: clone the bundle's fix1141 into /nvme/nixgate-<tag> and run the 4 flake checks
set -uo pipefail
B=$1; TAG=$2
. ~/.nix-profile/etc/profile.d/nix.sh
D=/nvme/nixgate-$TAG; [ -d $D ] && mv $D /nvme/trash_ng_$RANDOM
git clone -q -b fix1141 $B $D && cd $D
echo "tree $(git log -1 --format='%h %s')"
date
nix --extra-experimental-features 'nix-command flakes' build \
  .#checks.x86_64-linux.installcheck-pg17 .#checks.x86_64-linux.installcheck-pg18 \
  .#checks.x86_64-linux.tap-pg17 .#checks.x86_64-linux.tap-pg18 -L --keep-going --no-link
echo "nix build rc=$?"
date
echo NIXGATE_DONE
