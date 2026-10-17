#!/bin/bash
set -uo pipefail
date
if [ -L /nix ]; then sudo rm /nix; fi
sudo mkdir -p /nix /nvme/nixstore; sudo chown admin /nix /nvme/nixstore
mountpoint -q /nix || sudo mount --bind /nvme/nixstore /nix
sudo chown admin /nix
[ -d /nvme/nix ] && mv /nvme/nix /nvme/trash_nix_$RANDOM
ls -ld /nix; df -h /nix | tail -1
if [ ! -e ~/.nix-profile/etc/profile.d/nix.sh ]; then
  curl -sSfL https://nixos.org/nix/install -o /nvme/nix-install.sh
  sh /nvme/nix-install.sh --no-daemon
fi
. ~/.nix-profile/etc/profile.d/nix.sh
nix --version
mkdir -p ~/.config/nix; printf "experimental-features = nix-command flakes\nmax-jobs = 8\ncores = 8\n" > ~/.config/nix/nix.conf
date; echo NIXINST_DONE
