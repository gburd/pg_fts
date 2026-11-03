#!/bin/bash
bash /tmp/clean.sh >/dev/null 2>&1
bash /tmp/rep.sh v1151 /tmp/v1151.tgz > /nvme/rep_v1151.log 2>&1
bash /tmp/clean.sh >/dev/null 2>&1
bash /tmp/rep.sh main /tmp/main.tgz > /nvme/rep_main.log 2>&1
echo REP_ALL_DONE > /nvme/REP_ALL_DONE
