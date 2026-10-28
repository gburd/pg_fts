#!/bin/bash
set -uo pipefail
PFX=/nvme/pg17asan
which clang >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang >/dev/null 2>&1
which clang
S=/nvme/pg17asan-src; [ -d $S ] || { mkdir -p $S; tar xjf /nvme/postgresql-17.10.tar.bz2 -C $S --strip-components=1; }
cd $S && CC=clang CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1" ./configure --prefix=$PFX --enable-cassert --enable-debug --without-icu --with-llvm=no >/nvme/iss/asan-cfg.log 2>&1 && make -j32 >/nvme/iss/asan-mk.log 2>&1 && make install >/dev/null 2>&1 || { echo ASAN_PG_BUILD_FAIL; exit 1; }
echo ASANPG_DONE
