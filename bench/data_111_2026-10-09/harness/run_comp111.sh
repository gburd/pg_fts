#!/bin/bash
# competitor host: cluster, latency + in-run tps (lat3.sh), extra bands, then settled tps x2
ENG=$1
bash /tmp/cluster3.sh $ENG > /tmp/cluster.log 2>&1
cd /tmp; bash /tmp/lat3.sh $ENG /nvme/out > /nvme/lat.log 2>&1
bash /tmp/extra_bands.sh $ENG /nvme/out > /nvme/extra.log 2>&1
for r in 1 2; do bash /tmp/tps2_110.sh $ENG /nvme/out/tps_settled_r$r.txt > /dev/null 2>&1; done
echo RUN_DONE >> /nvme/lat.log
