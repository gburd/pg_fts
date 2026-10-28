#!/bin/bash
# crash/dup rate: 3 runs x {PG17,PG18} x {v1142,fix}, 8 inserters x 3000 rows (flush threshold 20), 8 readers x 300
for r in 1 2 3 4 5; do for M in 17 18; do for L in v1142 fix; do
  out=$(bash /tmp/dstress.sh $M $L 8 8 3000 300 2>&1)
  echo "run $r PG$M $L: $(echo "$out" | grep -E '^PG' | sed 's/inserters.*secs=/secs=/') | $(echo "$out" | grep -oE 'dup_top10=[0-9]+ dup_top1000=[0-9]+' | sort | uniq -c | tr '\n' ' ') | $(echo "$out" | grep -E 'segfaults') | cores=$(echo "$out" | grep -c '^core ') start_failed=$(echo "$out" | grep -c START_FAILED) connfail=$(echo "$out" | grep -c 'shutting down\|recovery mode') frame0: $(echo "$out" | grep -m1 '^#0' | grep -oE 'in [a-z_0-9]+ ')"
done; done; done
echo DSRATE_DONE
