#!/bin/bash
# round-3 gate on cad8cba: main gate (both majors) -> ASan smoke -> upgrade -> nix flake checks, sequential
bash /tmp/r3/gate141r2.sh; grep -E "^==|rc=|ALL CLEAN|DONE" /nvme/b3/gate141r3.log | tail -40 > /nvme/b3/r3-gate-summary.txt
bash /tmp/r3/asanfinal.sh > /nvme/b3/r3-asan.out 2>&1
bash /tmp/r3/upg141r2.sh > /nvme/b3/r3-upg.out 2>&1
bash /tmp/r3/nixgate.sh /nvme/b3/r3.bundle r3 > /nvme/b3/r3-nix.out 2>&1
echo R3ALL_DONE
