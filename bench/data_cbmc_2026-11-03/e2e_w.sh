#!/bin/bash
# e2e_widthbyte.sh -- does a corrupt FOR width byte inside a posting block make
# the ranked loader (wand_load_block) read past its palloc(bytelen) copy?
# Run on an EC2 host with the ASan PG17 at /nvme/pg17asan and a pg_fts tree at
# $1 (built here with ASan).  Prints ASan's verdict for the ranked query and,
# as the control, for count(*) (bm25_decode_term, which checks the columns).
set -u
T=$1
W=${2:-64}
NOBUILD=${3:-0}
PFX=/nvme/pg17asan
export ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=0:halt_on_error=1:print_stacktrace=1:verify_asan_link_order=0:detect_odr_violation=0"
export PATH=$PFX/bin:$PATH
ulimit -s 32768
cd "$T" || exit 1
if [ "$NOBUILD" != 1 ]; then
make -s clean >/dev/null 2>&1
make -s CC=clang PG_CONFIG=$PFX/bin/pg_config with_llvm=no \
	COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1" SHLIB_LINK="-fsanitize=address" >build.log 2>&1 \
	|| { echo BUILD_FAIL; tail -5 build.log; exit 1; }
make -s PG_CONFIG=$PFX/bin/pg_config with_llvm=no install >/dev/null 2>&1 || { echo INSTALL_FAIL; exit 1; }
fi
D=/nvme/e2e_data; [ -d $D ] && mv $D /nvme/trash_e2e_$RANDOM
initdb -D $D >/dev/null 2>&1 || { echo INITDB_FAIL; exit 1; }
echo "port = 5499" >> $D/postgresql.conf
printf "unix_socket_directories='/tmp'\nlisten_addresses=''\nfsync=off\nmax_stack_depth='24MB'\n" >> $D/postgresql.conf
echo "log_min_messages = warning" >> $D/postgresql.conf
pg_ctl -D $D -l $D/log -w start >/dev/null || { echo START_FAIL; exit 1; }
P="psql -X -q -h /tmp -p 5499 -d postgres -v ON_ERROR_STOP=1"
$P <<'SQL'
CREATE EXTENSION pg_fts;
CREATE TABLE t (id int, body ftsdoc);
-- every row has 'alpha': its posting list fills many 128-posting blocks
INSERT INTO t SELECT g, to_ftsdoc('simple', 'alpha beta' || (g % 7)) FROM generate_series(1, 5000) g;
CREATE INDEX t_fts ON t USING fts (body);
CHECKPOINT;
SQL
REL=$($P -Atc "SELECT pg_relation_filepath('t_fts')")
[ -n "$REL" ] || { echo NO_RELPATH; tail -5 $D/log; exit 1; }
echo "baseline ranked: $($P -Atc "SELECT count(*) FROM (SELECT id FROM t WHERE body @@@ 'alpha'::ftsquery ORDER BY body <=> 'alpha'::ftsquery LIMIT 10) s")"
pg_ctl -D $D -w stop -m fast >/dev/null
# Corrupt: on the first posting page, set the FIRST block's docid-column width
# byte (the byte right after the 28-byte block header) to 64.  count, bytelen
# and posbytelen are untouched, so the page-fit guard still passes; the docid
# column now claims 1 + 128*64/8 = 1025 bytes, far more than bytelen.
python3 - "$D/$REL" "$W" <<'PY'
import struct, sys
path = sys.argv[1]; W = int(sys.argv[2])
B = 8192; HDR = 28; BM25_POSTING = 1 << 2
with open(path, 'r+b') as f:
    data = f.read()
    for base in range(0, len(data), B):
        flags = struct.unpack_from('<H', data, base + 8184)[0]
        lower = struct.unpack_from('<H', data, base + 12)[0]
        if not (flags & BM25_POSTING) or lower <= 24:
            continue
        cnt, mtf, mdl, hi, lo, bytelen, posb = struct.unpack_from('<7I', data, base + 24)
        if cnt != 128:
            continue
        print(f"page {base // B}: block count={cnt} bytelen={bytelen} width={data[base + 24 + HDR]} -> {W}")
        f.seek(base + 24 + HDR); f.write(bytes([W]))
        break
    else:
        print("NO_FULL_BLOCK_FOUND"); sys.exit(1)
PY
pg_ctl -D $D -l $D/log -w start >/dev/null
for q in \
	"SELECT count(*) FROM (SELECT id FROM t WHERE body @@@ 'alpha'::ftsquery ORDER BY body <=> 'alpha'::ftsquery LIMIT 10) s" \
	"SELECT count(*) FROM t WHERE body @@@ 'alpha'::ftsquery"; do
	out=$($P -Atc "$q" 2>&1); rc=$?
	echo "query: $q"
	echo "  rc=$rc out=$(echo "$out" | tail -1)"
	sleep 1
done
echo "ASan reports in server log: $(grep -c 'ERROR: AddressSanitizer' $D/log)"
grep -A6 'ERROR: AddressSanitizer' $D/log | grep -E 'AddressSanitizer|READ of|#[0-4] ' | head -8
pg_ctl -D $D -w stop -m immediate >/dev/null 2>&1
