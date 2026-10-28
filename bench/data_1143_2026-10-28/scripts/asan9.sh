#!/bin/bash
# #9 under the ASan-built PG17: run the short-dfs probes against 1.14.2 and 1.14.3 builds; report ASan lines.
set -uo pipefail
G=/nvme/iss/gate; exec > $G/asan9.log 2>&1
export ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=0:print_stacktrace=1:verify_asan_link_order=0:detect_odr_violation=0"
ulimit -s 32768
for L in v1142 fix; do
  PFX=$G/asanpfx-$L; [ -d $PFX ] && mv $PFX /nvme/trash_a9_$RANDOM; cp -a /nvme/pg17asan $PFX
  T=$G/asan9-$L; [ -d $T ] && mv $T /nvme/trash_a9_$RANDOM; mkdir -p $T
  if [ $L = v1142 ]; then tar xzf /nvme/iss/iss_rel1142.tgz -C $T; else tar xzf $G/final.tgz -C $T; fi
  cd $T
  make CC=clang PG_CONFIG="$PFX/bin/pg_config" with_llvm=no COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1 -DUSE_ASSERT_CHECKING" SHLIB_LINK="-fsanitize=address" >$G/asan9-$L-build.log 2>&1 || { echo "$L BUILD FAIL"; continue; }
  make install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1
  D=$G/asan9data-$L; [ -d $D ] && mv $D /nvme/trash_a9_$RANDOM
  $PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=5990\nunix_socket_directories='/tmp'\nlisten_addresses=''\nfsync=off\nmax_stack_depth='24MB'\nlog_min_messages=info\n" >> $D/postgresql.conf
  $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  $PFX/bin/createdb -h /tmp -p 5990 -U postgres a9
  echo "== $L ($(grep default_version pg_fts.control)) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
  $PFX/bin/psql -X -At -h /tmp -p 5990 -U postgres -d a9 -f /nvme/iss/r/s9.sql 2>&1
  $PFX/bin/psql -X -At -h /tmp -p 5990 -U postgres -d a9 -f /nvme/iss/r/p9b.sql 2>&1
  $PFX/bin/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1
  echo "   AddressSanitizer lines in server log: $(grep -ciE 'AddressSanitizer' $D/log); 'write past chunk end': $(grep -c 'past chunk end' $D/log); server crashed: $(grep -c 'terminated by signal' $D/log)"
done
echo ASAN9_DONE
