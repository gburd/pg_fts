#!/bin/bash
# ASan smoke exactly as the CI sanitizers job runs it, against an ASan PG 17 build (17.10 source here; CI uses 17.6).
set -uo pipefail
G=/nvme/fp/gate; mkdir -p $G
PFX=/nvme/pg17asan
if [ ! -x $PFX/bin/postgres ]; then
  which clang >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang >/dev/null 2>&1
  S=/nvme/pg17asan-src; [ -d $S ] || { mkdir -p $S; tar xjf /nvme/postgresql-17.10.tar.bz2 -C $S --strip-components=1; }
  (cd $S && CC=clang CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1" ./configure --prefix=$PFX --enable-cassert --enable-debug --without-icu --with-llvm=no >$G/asan-cfg.log 2>&1 && make -j32 >$G/asan-mk.log 2>&1 && make install >/dev/null 2>&1) || { echo ASAN_PG_BUILD_FAIL; exit 1; }
fi
export ASAN_OPTIONS=detect_leaks=0
T=$G/asantree; [ -d $T ] && mv $T /nvme/trash_as_$RANDOM; mkdir -p $T; tar xzf /nvme/fp/final.tgz -C $T; cd $T
make CC=clang PG_CONFIG="$PFX/bin/pg_config" with_llvm=no COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1 -DUSE_ASSERT_CHECKING" SHLIB_LINK="-fsanitize=address" >$G/asan-ext.log 2>&1 || { echo EXT_BUILD_FAIL; exit 1; }
make install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1 || { echo EXT_INSTALL_FAIL; exit 1; }
echo "tree $(cat GITREV) ext so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8) $(grep default_version pg_fts.control)"
python3 - <<'PY' > $G/asan_step.sh
y=open('.github/workflows/ci.yml').read()
i=y.index('- name: Smoke the in-process paths under an ASan-built PostgreSQL')
j=y.index('        run: |', i); k=y.index('      - name:', j)
print('\n'.join(l[10:] for l in y[j:k].split('\n')[1:]))
PY
D="$PWD/asandata"
PFX=$PFX bash -eo pipefail $G/asan_step.sh > $G/asan_step.log 2>&1; rc=$?
echo "asan step rc=$rc; $(grep -E 'asan_smoke: all checks passed|ERROR' $G/asan_step.log | head -2 | tr '\n' ' ')"
$PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
echo "AddressSanitizer lines in server log: $(grep -ciE 'AddressSanitizer' $D/log)"
echo ASAN142_DONE
