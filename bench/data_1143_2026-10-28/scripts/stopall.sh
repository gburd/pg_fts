#!/bin/bash
# stop every postgres cluster on this host cleanly (by data dir), report what was running
for pm in $(pgrep -x postgres -P 1 2>/dev/null) $(pgrep -f 'bin/postgres -D' 2>/dev/null); do :; done
ps -eo pid,args | awk '/bin\/postgres( |$)/ && / -D /{print}' | while read pid rest; do
  d=$(echo "$rest" | sed -E 's/.* -D ([^ ]+).*/\1/'); b=$(echo "$rest" | awk '{print $1}' | sed 's#/postgres$##')
  echo "stopping $d ($b)"; $b/pg_ctl -D $d -m fast -w stop >/dev/null 2>&1 || kill $pid
done
sleep 2; echo "postgres processes left: $(pgrep -c postgres)"
