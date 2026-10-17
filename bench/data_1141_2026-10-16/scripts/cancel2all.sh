#!/bin/bash
p=55700
for r in 200000 400000; do for t in v140 cap1m fix cap8m; do p=$((p+1)); bash /tmp/cancel2.sh $t $r $p > /nvme/b3/c2-$t-$r.out 2>&1 & done; done
wait; cat /nvme/b3/c2-*-*.out | grep rows=; echo CANCEL2_DONE
