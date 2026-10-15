#!/bin/bash
# wait for TPS_DONE, then replace the running `all` (now in cold) with the fixed cold + write
while ! grep -q TPS_DONE /nvme/out/run.log 2>/dev/null; do sleep 5; done
pid=$(pgrep -f "bash /tmp/pgts_metal.sh all" | head -1)
[ -n "$pid" ] && kill -- -$(ps -o pgid= -p $pid | tr -d ' ') 2>/dev/null
sleep 3
pkill -x pgbench 2>/dev/null
mv /nvme/out/cold.txt /nvme/out/cold.killed 2>/dev/null
echo "[$(date -u +%FT%TZ)] watcher: replaced cold phase (statement_timeout + timeout skips)" >> /nvme/out/run.log
bash /tmp/pgts_metal2.sh cold; bash /tmp/pgts_metal2.sh write
echo "[$(date -u +%FT%TZ)] ALL_DONE" >> /nvme/out/run.log
