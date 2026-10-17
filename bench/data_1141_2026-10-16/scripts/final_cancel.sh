#!/bin/bash
# S2: re-measure bulkdelete RSS + cancel latency on the FINAL tree (6a91cd7) at 200k and 400k, PG18,
# reporter settings (sidecar off, mwm=4GB), using the round-1 cancel2.sh unchanged.
set -uo pipefail
R=/nvme/b3/repro; P18=/nvme/pg18
[ -d $R/pg-final ] && mv $R/pg-final /nvme/trash_pf_$RANDOM
cp -a $P18 $R/pg-final
W=/nvme/b3/tree-final; [ -d $W ] && mv $W /nvme/trash_tf_$RANDOM; mkdir -p $W; tar xzf /nvme/b3/final.tgz -C $W
cd $W && make -s clean PG_CONFIG=$R/pg-final/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$R/pg-final/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$R/pg-final/bin/pg_config >/dev/null 2>&1 || { echo BUILD_FAIL; exit 1; }
echo "final so=$(md5sum $R/pg-final/lib/postgresql/pg_fts.so | cut -c1-8) $(grep default_version $R/pg-final/share/postgresql/extension/pg_fts.control)"
grep -c "nids > 0 && nids + np > batchmax\|nids + np > batchmax" $W/pg_fts_am.c | sed 's/^/flush-before-append marker count: /'
bash /tmp/cancel2.sh final 200000 55491
bash /tmp/cancel2.sh final 400000 55492
echo FINAL_CANCEL_DONE
