#!/bin/bash
# stop every /nvme/rm cluster and any running bt.sh / i20ab.sh (by pid, never pkill -f over ssh)
for p in $(pgrep -f "bash /tmp/rm/(bt|i20ab)\.sh"); do [ "$p" != "$$" ] && kill $p 2>/dev/null; done
for d in /nvme/rm/d*-*; do [ -f $d/postmaster.pid ] && kill -QUIT $(head -1 $d/postmaster.pid) 2>/dev/null; done
for d in /nvme/rm/src*/tmp_check/t_*_data/pgdata; do [ -f $d/postmaster.pid ] && kill -QUIT $(head -1 $d/postmaster.pid) 2>/dev/null; done
sleep 3; echo "postgres left: $(pgrep -f 'bin/postgres' | wc -l)"
