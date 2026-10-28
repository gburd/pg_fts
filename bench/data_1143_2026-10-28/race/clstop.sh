#!/bin/bash
# clstop.sh <bin> <datadir>: stop a cluster for certain (immediate, then SIGQUIT/SIGKILL the postmaster)
P=$1; D=$2
$P/pg_ctl -D $D -m immediate -w -t 20 stop >/dev/null 2>&1
pid=$(head -1 $D/postmaster.pid 2>/dev/null)
if [ -n "$pid" ] && kill -0 $pid 2>/dev/null; then kill -QUIT $pid; sleep 3; kill -0 $pid 2>/dev/null && kill -KILL $pid; sleep 1; fi
$P/pg_ctl -D $D status >/dev/null 2>&1 && echo "CLSTOP_FAILED $D" || true
