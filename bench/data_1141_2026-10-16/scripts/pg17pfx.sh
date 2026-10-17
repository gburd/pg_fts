#!/bin/bash
set -uo pipefail
for TAG in v140 fix; do
  case $TAG in v140) TGZ=rel140;; fix) TGZ=fix;; esac
  PFX=/nvme/b3/pg17-$TAG; [ -d $PFX ] || cp -a /nvme/pg17 $PFX
  S=/nvme/b3/src17-$TAG; [ -d $S ] && mv $S /nvme/trash_src_$RANDOM; mkdir -p $S; tar xzf /nvme/b3/$TGZ.tgz -C $S; cd $S
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "error|warning:" | head
  make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && echo "pg17-$TAG installed so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8) $($PFX/bin/postgres --version)"
done
echo PFX17_DONE
