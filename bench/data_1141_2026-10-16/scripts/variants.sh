#!/bin/bash
# build fix tree into pg-fix, and batch-cap variants (same tree, -DBM25_BULKDELETE_BATCH_MAX) into pg-capN
set -uo pipefail
R=/nvme/b3/repro
build() { # $1 tag $2 extra COPT
  local TAG=$1 PFX=$R/pg-$1 S=/nvme/b3/src-$1
  [ -d $PFX ] || cp -a /nvme/pg18 $PFX
  [ -d $S ] && mv $S /nvme/trash_src_$RANDOM; mkdir -p $S; tar xzf /nvme/b3/fix.tgz -C $S; cd $S
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
  make -s -j32 PG_CONFIG=$PFX/bin/pg_config COPT="$2" 2>&1 | grep -E "error|warning:" | head
  make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && echo "$TAG installed COPT='$2' so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)" || echo "$TAG INSTALL FAILED"
}
build fix ""
for n in 1 8 16; do build cap${n}m "-DBM25_BULKDELETE_BATCH_MAX=$((n*1024*1024))"; done
echo VARIANTS_DONE
