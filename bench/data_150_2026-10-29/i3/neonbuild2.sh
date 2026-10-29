#!/bin/bash
# neonbuild2.sh: pre-install the toolchain neon pins (rust-toolchain.toml), then resume the release make
exec > /nvme/neon_build2.log 2>&1
export CARGO_HOME=/nvme/cargo RUSTUP_HOME=/nvme/rustup; . /nvme/cargo/env
cd /nvme/neon; cat rust-toolchain.toml
rustup show active-toolchain || rustup toolchain install $(grep -oE 'channel *= *"[^"]+"' rust-toolchain.toml | cut -d'"' -f2) --profile minimal
rustup show active-toolchain; cargo --version
date; BUILD_TYPE=release make -j$(nproc) -s > /nvme/neon_make2.log 2>&1; echo "neon make rc=$?"; date
tail -5 /nvme/neon_make2.log
ls target/release/ | grep -E "^(neon_local|pageserver|safekeeper|storage_broker|compute_ctl|storage_controller|endpoint_storage)$"
echo NEONBUILD2_DONE
