#!/bin/bash
# go2.sh <logfile> <commands...>: run a command string detached
L=$1; shift
nohup setsid bash -c "$*" > $L 2>&1 < /dev/null &
echo "started pid $!"
