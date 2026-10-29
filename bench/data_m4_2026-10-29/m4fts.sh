#!/bin/bash
# wait for the current engine loop, then pg_fts again with 64 GB for the build
while ! grep -q M4ALL_DONE /nvme/m4eng.out 2>/dev/null; do sleep 60; done
mv /nvme/m4/fts_build.txt /nvme/m4/fts_build_oom32g.txt 2>/dev/null
bash /tmp/m4/m4.sh engine fts; echo "engine fts (64G) rc=$?"
echo M4FTS_DONE
