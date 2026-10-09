#!/bin/bash
# H3b: pg_fts.shared_doclen on vs off, rare + mid k10, c16/c32/c64, 3 alternating rounds.
set -uo pipefail
OUT=/nvme/tv; B=/nvme/pg17/bin; D=/nvme/pgdata; P="$B/psql -h /tmp -U postgres -X -q -At"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/sd.log; }
pgb() { PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off -c pg_fts.shared_doclen=$3" $B/pgbench -h /tmp -U postgres -n -f /tmp/q_$1.sql -c $2 -j $(( $2 < 8 ? $2 : 8 )) -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | cut -d. -f1; }
$B/pg_ctl -D $D -w stop >/dev/null 2>&1; sed -i '/^huge_pages/d; /^min_dynamic_shared_memory/d' $D/postgresql.conf
sudo mount -o remount,huge=never /dev/shm; sudo sysctl -q vm.nr_hugepages=0
$B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
pgb rare 8 on >/dev/null
for round in 1 2 3; do for sd in on off; do
  log "round=$round sd=$sd rare c16=$(pgb rare 16 $sd) c32=$(pgb rare 32 $sd) c64=$(pgb rare 64 $sd) mid c16=$(pgb mid 16 $sd) c32=$(pgb mid 32 $sd) c64=$(pgb mid 64 $sd)"
done; done
log SD_DONE
