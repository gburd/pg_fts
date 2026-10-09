#!/bin/bash
# Is the slow-host loss the shared doclen copy sitting on 4 KiB pages (/dev/shm tmpfs, shmem THP never)?
# Configs, alternating, 2 rounds, each after restart + prewarm + warm-up:
#   A default: shared copy in /dev/shm, 4 KiB pages
#   B pg_fts.shared_doclen=off: private copies (anonymous memory, THP always)
#   C /dev/shm remounted huge=always: shared copy on 2 MiB shmem pages
#   D huge_pages=on + min_dynamic_shared_memory=256MB: DSM carved from the main segment (hugetlb)
set -uo pipefail
OUT=/nvme/tv; B=/nvme/pg17/bin; D=/nvme/pgdata; P="$B/psql -h /tmp -U postgres -X -q -At"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/fix.log; }
pgb() { PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off ${PGX:-}" $B/pgbench -h /tmp -U postgres -n -f /tmp/q_$1.sql -c $2 -j $(( $2 < 8 ? $2 : 8 )) -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | cut -d. -f1; }
# where does a backend's doclen copy live, and on what pages?  run one rare query, read its smaps
where() {   # in ONE session: run the ranked query, then read that backend's own smaps
  $P -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "$(sed 's/;$//' /tmp/q_rare.sql)" -c "SELECT pg_read_file('/proc/self/smaps')" > /tmp/smaps.out 2>/dev/null
  python3 /tmp/smaps_sum.py /tmp/smaps.out
}
cfg() {
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1
  sed -i '/^huge_pages/d; /^min_dynamic_shared_memory/d' $D/postgresql.conf
  sudo mount -o remount,huge=never /dev/shm; sudo sysctl -q vm.nr_hugepages=0; PGX=""
  case $1 in
    B) PGX="-c pg_fts.shared_doclen=off" ;;
    C) sudo mount -o remount,huge=always /dev/shm ;;
    D) sudo sysctl -q vm.nr_hugepages=17300; printf "huge_pages=on\nmin_dynamic_shared_memory=256MB\n" >> $D/postgresql.conf ;;
  esac
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null || { log "START FAILED cfg=$1"; tail -5 $D/server.log | tee -a $OUT/fix.log; return 1; }
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  PGX="$PGX" pgb rare 8 >/dev/null
  log "cfg=$1 hp_status=$($P -c 'SHOW huge_pages_status') shm_mount=$(mount | grep ' /dev/shm ' | grep -o 'huge=[a-z_]*' || echo default) shdl_slots=$($P -c 'SELECT count(*) FROM fts_shared_doclen_stats()' 2>/dev/null) mem: $([ $1 = B ] || where)"
}
for round in 1 2; do for c in A B C D; do cfg $c || continue
  export PGX
  log "round=$round cfg=$c rare c16=$(pgb rare 16) c64=$(pgb rare 64) mid c16=$(pgb mid 16) common c16=$(pgb common 16) count c16=$(pgb count 16)"
done; done
cfg A >/dev/null
log FIX_DONE
