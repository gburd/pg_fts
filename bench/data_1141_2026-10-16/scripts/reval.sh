#!/bin/bash
TAGS="v140 fix2" bash /tmp/bug3.sh > /nvme/b3/bug3-final.out 2>&1 &
bash /tmp/bug2d.sh > /nvme/b3/bug2d-final.out 2>&1 &
TAG=fix2 bash /tmp/bug2e.sh > /nvme/b3/bug2e-fix2.out 2>&1 &
wait; echo REVAL_DONE
