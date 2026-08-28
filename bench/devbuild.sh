#!/usr/bin/env bash
# Local build+install+run helper for pg_fts dev iteration against a WRITABLE,
# source-built PostgreSQL (e.g. the /nvme/pgNN prefix on an EC2 bench host, or
# any `./configure --prefix=...` build).  It does NOT work against the read-only
# Nix-store PG in the dev shell -- for the local functional gate use
# `nix build .#checks.<sys>.installcheck-pgNN`; use this on the bench host where
# latency/parity baselines are taken (plan Phase 0b).
#
# Requires pg_config for the target PG on PATH.
# Usage:
#   bench/devbuild.sh build          # make + install into the target PG
#   bench/devbuild.sh start          # initdb + start scratch cluster on :55462
#   bench/devbuild.sh stop           # stop + remove scratch cluster
#   bench/devbuild.sh psql ...       # psql into the scratch cluster
set -euo pipefail
PORT=55462; SOCK=/tmp; PGDATA=/tmp/pgfts_dev
SRV=$(pg_config --includedir-server)
GCC_CFLAGS="-Wall -Wmissing-prototypes -Wpointer-arith -Wdeclaration-after-statement \
-Werror=vla -Wendif-labels -Wformat-security -fno-strict-aliasing -fwrapv \
-fexcess-precision=standard -Wno-format-truncation -O2 -g -fPIC \
-I. -I$SRV -I$SRV/internal -D_GNU_SOURCE"

case "${1:-build}" in
  build)
    make CC=cc CFLAGS="$GCC_CFLAGS" "${@:2}" >/tmp/devbuild.log 2>&1 \
      && make CC=cc CFLAGS="$GCC_CFLAGS" install >>/tmp/devbuild.log 2>&1 \
      && echo "built+installed" || { echo BUILD_FAIL; tail -20 /tmp/devbuild.log; exit 1; } ;;
  start)
    [ -d "$PGDATA" ] || initdb -D "$PGDATA" -U fedora >/dev/null 2>&1
    grep -q "^port=$PORT" "$PGDATA/postgresql.conf" || {
      echo "unix_socket_directories='$SOCK'" >> "$PGDATA/postgresql.conf"
      echo "port=$PORT" >> "$PGDATA/postgresql.conf"
      echo "shared_buffers=2GB" >> "$PGDATA/postgresql.conf"
      echo "maintenance_work_mem=512MB" >> "$PGDATA/postgresql.conf"; }
    pg_ctl -D "$PGDATA" -w -o "-k $SOCK" -l /tmp/pgfts_dev.log start >/dev/null 2>&1 || \
      pg_ctl -D "$PGDATA" -w -o "-k $SOCK" -l /tmp/pgfts_dev.log restart >/dev/null 2>&1
    createdb -h "$SOCK" -p "$PORT" bench 2>/dev/null || true
    echo "cluster up on $SOCK:$PORT db=bench" ;;
  stop)
    pg_ctl -D "$PGDATA" stop -m immediate >/dev/null 2>&1 || true
    find "$PGDATA" -depth -delete 2>/dev/null || true; echo "stopped+removed" ;;
  psql) shift; psql -h "$SOCK" -p "$PORT" -d bench "$@" ;;
  *) echo "unknown: $1"; exit 1 ;;
esac
