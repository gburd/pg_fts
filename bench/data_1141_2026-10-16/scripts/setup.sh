#!/bin/bash
# per-version PG18 prefixes with the matching pg_fts installed: /nvme/b3/repro/pg-<tag>
set -uo pipefail
R=/nvme/b3/repro
for TAG in ${TAGS:-v100 v130 v140 fix}; do
  case $TAG in v100) TGZ=rel100;; v130) TGZ=rel130;; v140) TGZ=rel140;; fix) TGZ=fix;; *) TGZ=$TAG;; esac
  PFX=$R/pg-$TAG
  [ -d $PFX ] || cp -a /nvme/pg18 $PFX
  S=/nvme/b3/src-$TAG; [ -d $S ] && mv $S /nvme/trash_src_$RANDOM; mkdir -p $S; tar xzf /nvme/b3/$TGZ.tgz -C $S
  cd $S
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
  make -s -j32 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "error|warning:" | head
  make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && echo "$TAG installed: $(grep default_version pg_fts.control) so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)" || echo "$TAG INSTALL FAILED"
done
echo SETUP_DONE
