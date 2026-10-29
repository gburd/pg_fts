#!/bin/bash
# neonbuild.sh: build Neon (release) + its PG 17 on a Debian 13 host, then pg_fts against Neon's PG 17.
# Log /nvme/neon_build.log; ends NEONBUILD_DONE.  The pg_fts tree arrives later as /nvme/final.tgz.
set -uo pipefail
bash /tmp/boot.sh || exit 1
exec > /nvme/neon_build.log 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential libtool libreadline-dev zlib1g-dev flex bison libseccomp-dev \
  libssl-dev clang pkg-config libpq-dev cmake postgresql-client protobuf-compiler libprotobuf-dev libcurl4-openssl-dev openssl lsof libicu-dev \
  python3-venv git libipc-run-perl >/dev/null || { echo APT_FAIL; exit 1; }
protoc --version
export CARGO_HOME=/nvme/cargo RUSTUP_HOME=/nvme/rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/nvme/rustup.log 2>&1 || { echo RUSTUP_FAIL; exit 1; }
. /nvme/cargo/env; rustc --version
cd /nvme; git clone -q --recursive https://github.com/neondatabase/neon.git || { echo CLONE_FAIL; exit 1; }
cd neon; echo "neon $(git log -1 --format='%h %cs %s')"; git submodule status | head -5
date; BUILD_TYPE=release make -j$(nproc) -s > /nvme/neon_make.log 2>&1; echo "neon make rc=$?"; date
tail -5 /nvme/neon_make.log
ls pg_install/ 2>/dev/null; ls pg_install/v17/bin/ 2>/dev/null | head
echo NEONBUILD_DONE
