#!/bin/bash
# ASan smoke exactly as the CI sanitizers job runs it, against an ASan PG 17 build (17.10 source; CI uses 17.6).
set -uo pipefail
G=/nvme/iss/gate; mkdir -p $G
exec > $G/asan143.log 2>&1
PFX=/nvme/pg17asan
export ASAN_OPTIONS=detect_leaks=0
T=$G/asantree; [ -d $T ] && mv $T /nvme/trash_as_$RANDOM; mkdir -p $T; tar xzf $G/final.tgz -C $T; cd $T
make -s clean PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1
make CC=clang PG_CONFIG="$PFX/bin/pg_config" with_llvm=no COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1 -DUSE_ASSERT_CHECKING" SHLIB_LINK="-fsanitize=address" >$G/asan-ext.log 2>&1 || { echo EXT_BUILD_FAIL; exit 1; }
make install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1 || { echo EXT_INSTALL_FAIL; exit 1; }
echo "tree $(cat GITREV) ext so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8) $(grep default_version pg_fts.control); short-dfs probe in smoke: $(grep -c bm25_short_dfs_ok test/asan_smoke.sql)"
python3 - <<'PY' > $G/asan_step.sh
y=open('.github/workflows/ci.yml').read()
i=y.index('- name: Smoke the in-process paths under an ASan-built PostgreSQL')
j=y.index('        run: |', i); k=y.index('      - name:', j)
print('\n'.join(l[10:] for l in y[j:k].split('\n')[1:]))
PY
D="$PWD/asandata"
[ -s $G/asan_step.sh ] || { echo ASAN_STEP_EXTRACT_FAIL; exit 1; }
PFX=$PFX bash -eo pipefail $G/asan_step.sh > $G/asan_step.log 2>&1; rc=$?
echo "asan step rc=$rc; $(grep -E 'asan_smoke: all checks passed|ERROR' $G/asan_step.log | head -2 | tr '\n' ' ')"
grep -E "bm25_short_dfs_ok" -A3 $G/asan_step.log | head -5
$PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
echo "AddressSanitizer lines in server log: $(grep -ciE 'AddressSanitizer' $D/log); 'detected write past chunk end' lines: $(grep -c 'write past chunk end' $D/log)"
grep -q 'asan_smoke: all checks passed' $G/asan_step.log && [ $rc = 0 ] && [ -f $D/log ] || { echo ASAN_NOT_GREEN; exit 1; }
echo ASAN143_DONE
