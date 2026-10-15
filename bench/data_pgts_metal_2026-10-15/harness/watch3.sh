#!/bin/bash
echo "[$(date -u +%FT%TZ)] watch3: latency resumes (amendment 6: >10 s bands median of 3)" >> /nvme/out/run.log
RESUME=1 bash /tmp/pgts_metal2.sh lat
bash /tmp/pgts_metal2.sh agree; bash /tmp/pgts_metal2.sh tps; bash /tmp/pgts_metal2.sh cold; bash /tmp/pgts_metal2.sh write
echo "[$(date -u +%FT%TZ)] ALL_DONE" >> /nvme/out/run.log
