#!/bin/bash
# Item 7: run the CI sanitizers smoke step's commands verbatim (bash -eo pipefail, as GitHub runs a step)
# against the ASan PG 17.10 prefix, for the real smoke and for two planted-failure copies.
set -uo pipefail
PFX=/nvme/pg17asan
export ASAN_OPTIONS=detect_leaks=0
T=/nvme/b3/asantree3; [ -d $T ] && mv $T /nvme/trash_as_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/final_r2.tgz -C $T; cd $T
make CC=clang PG_CONFIG="$PFX/bin/pg_config" with_llvm=no COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1 -DUSE_ASSERT_CHECKING" SHLIB_LINK="-fsanitize=address" >/nvme/b3/asan3-ext.log 2>&1 || { echo EXT_BUILD_FAIL; exit 1; }
make install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1 || { echo EXT_INSTALL_FAIL; exit 1; }
echo "ext so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
cp test/asan_smoke.sql /nvme/b3/asan_smoke.real.sql
sed "s/SELECT pg_temp.ok('or_ok', count(\*) > 0)/SELECT pg_temp.ok('or_ok', count(*) < 0)/" test/asan_smoke.sql > /nvme/b3/asan_smoke.false.sql
sed "s/SELECT pg_temp.ok('count_ok', fts_count/SELECT pg_temp.ok('count_ok', NULL::bool AND fts_count/" test/asan_smoke.sql > /nvme/b3/asan_smoke.null.sql
echo "planted diffs: false=$(diff test/asan_smoke.sql /nvme/b3/asan_smoke.false.sql | grep -c '^>') null=$(diff test/asan_smoke.sql /nvme/b3/asan_smoke.null.sql | grep -c '^>')"
# the step body from .github/workflows/ci.yml, with PFX/port fixed for this host
python3 - <<'PY' > /nvme/b3/asan_step.sh
import re
y=open('.github/workflows/ci.yml').read()
i=y.index('- name: Smoke the in-process paths under an ASan-built PostgreSQL')
j=y.index('        run: |', i); k=y.index('      - name:', j)
body=[l[10:] for l in y[j:k].split('\n')[1:]]
print('\n'.join(body))
PY
for v in real false null; do
  D="$PWD/asandata"; [ -d $D ] && { $PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; mv $D /nvme/trash_as_$RANDOM; }
  cp /nvme/b3/asan_smoke.$v.sql test/asan_smoke.sql
  PFX=$PFX bash -eo pipefail /nvme/b3/asan_step.sh > /nvme/b3/asan3_step_$v.log 2>&1; rc=$?
  echo "== $v: step rc=$rc; $(grep -E 'asan_smoke: (check|all)|ERROR' /nvme/b3/asan3_step_$v.log | head -2 | tr '\n' ' ')"
  $PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
  grep -ciE "AddressSanitizer" $D/log | sed 's/^/   asan reports in log: /'
done
cp /nvme/b3/asan_smoke.real.sql test/asan_smoke.sql
echo ASANCI2_DONE
