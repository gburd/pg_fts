#!/bin/bash
# Fedora host prep: packages + XFS on ONE local NVMe instance-store disk at /nvme (user fedora)
set -uo pipefail
sudo dnf -y -q install gcc make bison flex readline-devel zlib-devel libicu-devel perl perl-FindBin perl-IPC-Run \
  bc unzip git python3 python3-pip xfsprogs numactl sysstat perf gdb tar bzip2 curl pkgconf-pkg-config \
  postgresql-private-devel >/dev/null 2>&1 || sudo dnf -y -q install gcc make bison flex readline-devel zlib-devel libicu-devel perl bc unzip git python3 xfsprogs numactl sysstat tar bzip2 >/dev/null
ROOT=$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//; s|/dev/||')
DEV=$(lsblk -dn -b -o NAME,SIZE,TYPE,MODEL | awk -v r="$ROOT" '$3=="disk" && $1!=r && /Instance Storage/ {print "/dev/"$1; exit}')
[ -z "$DEV" ] && DEV=$(lsblk -dn -b -o NAME,SIZE,TYPE | awk -v r="$ROOT" '$3=="disk" && $1!=r {print $2, "/dev/"$1}' | sort -n | tail -1 | awk '{print $2}')
echo "nvme dev: $DEV (root $ROOT); model: $(lsblk -dn -o MODEL $DEV)"
sudo mkfs.xfs -f $DEV >/dev/null && sudo mkdir -p /nvme && sudo mount -o noatime $DEV /nvme && sudo chown fedora /nvme
df -hT /nvme | tail -1
echo BOOT_DONE
