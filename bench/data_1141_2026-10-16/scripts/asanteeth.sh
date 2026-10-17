#!/bin/bash
# teeth: plant a 1-byte heap overflow in fts_matchsel's path (bm25_estimate_matchfrac) and confirm the
# CI smoke step catches it; then restore the real build.
set -o pipefail
PFX=/nvme/pg17asan; export ASAN_OPTIONS=detect_leaks=0
T=/nvme/b3/asanteeth; [ -d $T ] && mv $T /nvme/trash_at_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/final2.tgz -C $T; cd $T
python3 - <<'PY'
s=open("pg_fts_am_scan.c").read()
a="""	hits = bm25_query_segdf(index, q, &meta, n, &noest);"""
b="""	{ char *volatile x = malloc(16); x[16] = 1; free(x); }
	hits = bm25_query_segdf(index, q, &meta, n, &noest);"""
assert s.count(a)==1; open("pg_fts_am_scan.c","w").write(s.replace(a,b))
PY
make CC=clang PG_CONFIG="$PFX/bin/pg_config" with_llvm=no COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1 -DUSE_ASSERT_CHECKING" SHLIB_LINK="-fsanitize=address" >/dev/null 2>&1 && make install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1 || { echo BUILD_FAIL; exit 1; }
ulimit -s 32768
export ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=0:abort_on_error=1:print_stacktrace=1:verify_asan_link_order=0:detect_odr_violation=0"
D=/nvme/b3/asanteethdata; [ -d $D ] && mv $D /nvme/trash_at_$RANDOM
$PFX/bin/initdb -D "$D" -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "unix_socket_directories='/tmp'\nlisten_addresses=''\nfsync=off\nmax_stack_depth='24MB'\nshared_buffers=256MB\nport=55478\n" >> "$D/postgresql.conf"
$PFX/bin/pg_ctl -D "$D" -l "$D/log" -w start >/dev/null
$PFX/bin/createdb -h /tmp -p 55478 -U postgres smoke
$PFX/bin/psql -h /tmp -p 55478 -U postgres -d smoke -v ON_ERROR_STOP=1 -f test/asan_smoke.sql > /nvme/b3/asanteeth.out 2>&1; echo "smoke psql rc=$?"
grep -iE "heap-buffer-overflow|SUMMARY: AddressSanitizer" "$D/log" | head -3 && echo TEETH_CAUGHT || echo TEETH_MISSED
$PFX/bin/pg_ctl -D "$D" -m immediate -w stop >/dev/null 2>&1
cd /nvme/b3/asantree && make install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1 && echo restored
