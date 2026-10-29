#!/bin/bash
# M4 pg_fts rerun with the quoted query form (fresh copy of base, 192G build, W1/W2/W3)
mkdir -p /nvme/m4/run1_invalid && mv /nvme/m4/fts_* /nvme/m4/lat_fts_* /nvme/m4/run1_invalid/ 2>/dev/null
bash /tmp/m4/m4.sh engine fts; echo "engine fts rc=$?"
echo M4FTS3_DONE
