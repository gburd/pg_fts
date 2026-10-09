#!/bin/bash
# Huge pages for shared_buffers: does it remove the host-to-host spread?  On each host:
# (A) the current config (huge_pages=try, none reserved -> 4 KiB pages), then
# (B) vm.nr_hugepages reserved for shared_buffers + huge_pages=on, then (A) again, then (B) again.
# rare/mid/common/count c16 + rare c64, each after restart + prewarm + 10 s warm-up, 30 s.
set -uo pipefail
OUT=/nvme/tv; B=/nvme/pg17/bin; D=/nvme/pgdata; P="$B/psql -h /tmp -U postgres -X -q -At"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/hp.log; }
pgb() { PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/q_$1.sql -c $2 -j $(( $2 < 8 ? $2 : 8 )) -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | cut -d. -f1; }
# 32 GB shared_buffers + other shmem: reserve 17,000 x 2 MiB = 33.2 GiB
NHP=17000
mode() {
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1
  if [ $1 = huge ]; then
    sudo sysctl -q vm.nr_hugepages=$NHP; sed -i '/^huge_pages/d' $D/postgresql.conf; echo "huge_pages=on" >> $D/postgresql.conf
  else
    sed -i '/^huge_pages/d' $D/postgresql.conf; sudo sysctl -q vm.nr_hugepages=0
  fi
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null || { log "START FAILED mode=$1"; tail -5 $D/server.log | tee -a $OUT/hp.log; exit 1; }
  log "mode=$1 huge_pages_status=$($P -c 'SHOW huge_pages_status') HugePages_Total=$(awk '/HugePages_Total/{print $2}' /proc/meminfo) Free=$(awk '/HugePages_Free/{print $2}' /proc/meminfo)"
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  pgb rare 8 >/dev/null
}
for round in 1 2; do for m in 4k huge; do mode $m
  log "round=$round mode=$m rare c16=$(pgb rare 16) c64=$(pgb rare 64) mid c16=$(pgb mid 16) common c16=$(pgb common 16) count c16=$(pgb count 16)"
done; done
log HP_DONE
