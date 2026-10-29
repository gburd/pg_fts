#!/bin/bash
mv /nvme/m4/fts_build.txt /nvme/m4/fts_build_oom64g.txt 2>/dev/null
bash /tmp/m4/m4.sh engine fts; echo "engine fts (192G build) rc=$?"
echo M4FTS2_DONE
