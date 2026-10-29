#!/bin/bash
# nixgate151.sh <bundle> <tag>: clone the bundle's r20 into /nvme/nixgate-<tag> and run the 6 flake checks
set -uo pipefail
B=$1; TAG=$2
. ~/.nix-profile/etc/profile.d/nix.sh
D=/nvme/nixgate-$TAG; [ -d $D ] && mv $D /nvme/trash_ng_$RANDOM
git clone -q -b r151 $B $D && cd $D
echo "tree $(git log -1 --format='%h %s')"
date
nix --extra-experimental-features 'nix-command flakes' build \
  .#checks.x86_64-linux.installcheck-pg17 .#checks.x86_64-linux.installcheck-pg18 \
  .#checks.x86_64-linux.tap-pg17 .#checks.x86_64-linux.tap-pg18 \
  .#checks.x86_64-linux.tap-hooks-pg17 .#checks.x86_64-linux.tap-hooks-pg18 -L --keep-going --no-link
echo "nix build rc=$?"
date
echo NIXGATE_DONE
