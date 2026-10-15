#!/bin/bash
# host prep: packages + XFS on the largest local NVMe instance-store disk at /nvme
set -uo pipefail
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential bison flex libreadline-dev zlib1g-dev libicu-dev \
  pkg-config perl bc unzip git python3 python3-venv sysstat xfsprogs clang llvm lcov libipc-run-perl libtest-simple-perl \
  libxml2-utils xsltproc gdb >/dev/null
ROOT=$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//; s|/dev/||')
DEV=$(lsblk -dn -b -o NAME,SIZE,TYPE | awk -v r="$ROOT" '$3=="disk" && $1!=r {print $2, "/dev/"$1}' | sort -n | tail -1 | awk '{print $2}')
echo "nvme dev: $DEV (root $ROOT)"
sudo mkfs.xfs -f $DEV >/dev/null && sudo mkdir -p /nvme && sudo mount -o noatime $DEV /nvme && sudo chown admin /nvme
df -hT /nvme | tail -1
echo BOOT_DONE
