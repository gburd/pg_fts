#!/bin/bash
# pgc.sh <prefix-name> <data-name> <port> init|start|stop
X=$1; N=$2; P=$3; A=$4
B=/nvme/fp/$X/bin; D=/nvme/fp/d-$N
case $A in
init)
  [ -d $D ] && mv $D /nvme/trash_$RANDOM
  $B/initdb -D $D -U postgres --no-sync >/dev/null 2>&1 || exit 1
  cat >> $D/postgresql.conf <<CONF
port = $P
shared_buffers = 4GB
max_wal_size = 20GB
checkpoint_timeout = 30min
log_min_messages = info
max_connections = 200
autovacuum_naptime = 5s
fsync = off
synchronous_commit = off
full_page_writes = off
unix_socket_directories = '/tmp'
log_autovacuum_min_duration = 0
CONF
  ;;
start) $B/pg_ctl -D $D -l $D/log -w start >/dev/null && echo "started $N" ;;
stop) $B/pg_ctl -D $D -m fast -w stop >/dev/null && echo "stopped $N" ;;
esac
