#!/bin/bash
# A2 latency, wiki 2.19M, PG 17.10: arms v1143 / cur, interleaved (v1143, cur, v1143, cur), 3 runs of a2lat.sql each
for L in v1143 cur v1143 cur; do
  SO=/nvme/rm/so_cur17.so; [ $L = v1143 ] && SO=/nvme/rm/so_v1143_17.so
  bash /tmp/rm/a2lat.sh ${L}_$RANDOM $SO
done
echo A2ALL_DONE
