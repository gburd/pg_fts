#!/bin/bash
# CI sanitizers job, mirrored: PostgreSQL 17.10 built with -fsanitize=address (clang, cassert), pg_fts
# built with ASan, test/asan_smoke.sql, grep the server log.  Tree = /nvme/b3/final2.tgz.
set -o pipefail
PFX=/nvme/pg17asan
if [ ! -x $PFX/bin/postgres ]; then
  S=/nvme/b3/pgasan-src; [ -d $S ] && mv $S /nvme/trash_as_$RANDOM; mkdir -p $S; tar xjf /nvme/postgresql-17.10.tar.bz2 -C $S
  cd $S/postgresql-17.10
  CC=clang CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1" ./configure --prefix=$PFX --enable-cassert --enable-debug --without-icu --with-llvm=no >/nvme/b3/asan-cfg.log 2>&1 || { echo CFG_FAIL; exit 1; }
  make -j32 >/nvme/b3/asan-mk.log 2>&1 && make install >/dev/null 2>&1 || { echo PGBUILD_FAIL; exit 1; }
fi
echo "asan pg: $($PFX/bin/postgres --version 2>&1 | head -1)"
export ASAN_OPTIONS=detect_leaks=0
T=/nvme/b3/asantree; [ -d $T ] && mv $T /nvme/trash_as_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/final2.tgz -C $T; cd $T
echo "tree $(cat GITREV)"
make CC=clang PG_CONFIG="$PFX/bin/pg_config" with_llvm=no COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1 -DUSE_ASSERT_CHECKING" SHLIB_LINK="-fsanitize=address" >/nvme/b3/asan-ext.log 2>&1 || { echo EXT_BUILD_FAIL; tail /nvme/b3/asan-ext.log; exit 1; }
make install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1 || { echo EXT_INSTALL_FAIL; exit 1; }
ulimit -s 32768
export ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=0:abort_on_error=1:print_stacktrace=1:verify_asan_link_order=0:detect_odr_violation=0"
D=/nvme/b3/asandata; $PFX/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_as_$RANDOM
$PFX/bin/initdb -D "$D" -U postgres --no-locale -E UTF8 >/dev/null
printf "unix_socket_directories='/tmp'\nlisten_addresses=''\nfsync=off\nmax_stack_depth='24MB'\nshared_buffers=256MB\nport=55479\n" >> "$D/postgresql.conf"
$PFX/bin/pg_ctl -D "$D" -l "$D/log" -w start >/dev/null
$PFX/bin/createdb -h /tmp -p 55479 -U postgres smoke
$PFX/bin/psql -h /tmp -p 55479 -U postgres -d smoke -v ON_ERROR_STOP=1 -f test/asan_smoke.sql > /nvme/b3/asan-smoke.out 2>&1; echo "smoke psql rc=$?"
echo "true rows: $(grep -cE "^ t$" /nvme/b3/asan-smoke.out); false rows: $(grep -cE "^ f$" /nvme/b3/asan-smoke.out); ERROR lines: $(grep -c ERROR /nvme/b3/asan-smoke.out)"; grep -qE "^ f$" /nvme/b3/asan-smoke.out && echo SMOKE_FALSE_ROW
if grep -iE "heap-use-after-free|heap-buffer-overflow|stack-buffer-overflow|global-buffer-overflow|use-after-poison|SUMMARY: AddressSanitizer: (heap|stack|global|use)" "$D/log"; then echo ASAN_ERROR; else echo ASAN_CLEAN; fi
$PFX/bin/pg_ctl -D "$D" -w stop >/dev/null
echo ASAN141_DONE
