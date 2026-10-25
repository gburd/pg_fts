#!/bin/bash
# final 1.14.2 gate on tree 6d02f84: main gate (both majors), upgrade, ASan, nix flake -- sequential
cp /nvme/fp/fp_final.tgz /nvme/fp/final.tgz
bash /tmp/g/gate142.sh; echo "gate rc=$?"
bash /tmp/g/upg142.sh > /nvme/fp/final-upg.out 2>&1
bash /tmp/g/asan142.sh > /nvme/fp/final-asan.out 2>&1
bash /tmp/g/nixgate.sh /nvme/fp/fp_final.bundle final > /nvme/fp/final-nix.out 2>&1
echo FINAL_ALL_DONE
