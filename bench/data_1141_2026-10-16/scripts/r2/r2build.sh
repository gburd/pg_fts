#!/bin/bash
# r2build.sh <tgz> <tag>: build the tree into /nvme/b3/repro/pg-<tag> (PG18) and /nvme/b3/pg17-<tag> (PG17)
set -uo pipefail
TGZ=$1; TAG=$2
for M in 17 18; do
  if [ $M = 18 ]; then PFX=/nvme/b3/repro/pg-$TAG; else PFX=/nvme/b3/pg17-$TAG; fi
  [ -d $PFX ] || cp -a /nvme/pg$M $PFX
  S=/nvme/b3/src$M-$TAG; [ -d $S ] && mv $S /nvme/trash_src_$RANDOM; mkdir -p $S; tar xzf $TGZ -C $S; cd $S
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
  make -s -j32 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "error|warning:" | head
  make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && echo "$TAG PG$M installed so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8) $(grep default_version $PFX/share/postgresql/extension/pg_fts.control)" || echo "$TAG PG$M INSTALL FAILED"
done
echo R2BUILD_DONE
