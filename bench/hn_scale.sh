#!/usr/bin/env bash
# hn_scale.sh: the HackerNews scale test for pg_fts (bench/hn_corpus.py,
# bench/hn_queries.py).  It exists because the field report behind 1.18.1 (a
# wide boolean filter over 150M HackerNews documents raised "invalid memory
# alloc request size" in 549 of 3,762 queries and OOMed a 64 GiB container
# under 8 clients) was invisible at the 2.19M-row Wikipedia scale every
# earlier test used, and because benches timed queries but did not measure
# memory.
#
# Phases, each logged to $OUT:
#   load    COPY the tier into hn(id bigint, content text), then add the
#           stored ftsdoc column d and VACUUM ANALYZE
#   build   CREATE INDEX ... USING fts (d): time, index size, peak RSS of the
#           building backend
#   check   counts of three terms through the index vs a forced heap scan;
#           any mismatch fails the run (a fast wrong answer is a bug)
#   trace   every query of the trace, filter and ranked forms, one backend
#           per statement: ok/error, ms, the backend's peak RSS (VmHWM)
#   conc    the trace's filter statements from CLIENTS sessions at once,
#           counting failed statements.  To reproduce the field's memory cap,
#           start the server under one (systemd-run --user --scope -p
#           MemoryMax=64G pg_ctl ...); an OOM then shows up here as failed
#           sessions and a "terminated by signal 9" in the server log.
#
# usage: hn_scale.sh <pg_bindir> <corpus.tsv> <trace.tsv> <outdir> [phases...]
# env:   PGHOST/PGPORT/PGDATABASE for the server under test, CLIENTS (8),
#        MWM (maintenance_work_mem for the build, default 8GB)
set -uo pipefail
BIN=${1:?pg bindir}; CORPUS=${2:?corpus}; TRACE=${3:?trace}; OUT=${4:?outdir}; shift 4
PHASES=${*:-load build check trace conc}
CLIENTS=${CLIENTS:-8}; MWM=${MWM:-8GB}
export PATH=$BIN:$PATH
mkdir -p "$OUT"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$OUT/run.log"; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }
# Peak RSS (MiB) of the backend that ran $1; prints "rc ms peak_mib message".
one() {
  local o rc
  o=$(psql -X -q -At -v ON_ERROR_STOP=1 -c '\timing on' -c "$1" \
        -c "SELECT 'HWM ' || (regexp_match(pg_read_file('/proc/' || pg_backend_pid() || '/status'), 'VmHWM:\s+(\d+)'))[1]" 2>&1)
  rc=$?
  local ms hwm err
  ms=$(echo "$o" | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | head -1)
  hwm=$(echo "$o" | sed -n 's/^HWM \([0-9]*\)$/\1/p')
  err=$(echo "$o" | grep -m1 -E '^(psql:.*)?ERROR' | sed 's/.*ERROR: *//' | tr '\t' ' ')
  echo "$rc ${ms:-NA} $(( ${hwm:-0} / 1024 )) ${err:-}"
}

for ph in $PHASES; do case $ph in
load)
  log "load $(wc -l < "$CORPUS") rows from $CORPUS"
  q -c "CREATE EXTENSION IF NOT EXISTS pg_fts" -c "DROP TABLE IF EXISTS hn" \
    -c "CREATE TABLE hn (id bigint, content text)" \
    -c "\\copy hn FROM '$CORPUS' WITH (FORMAT text)"
  s=$(date +%s)
  q -c "ALTER TABLE hn ADD COLUMN d ftsdoc" -c "UPDATE hn SET d = to_ftsdoc('english', content)" \
    -c "VACUUM (FREEZE, ANALYZE) hn"
  log "load rows=$(q -c 'SELECT count(*) FROM hn') ftsdoc_s=$(( $(date +%s) - s )) heap=$(q -c "SELECT pg_size_pretty(pg_table_size('hn'))")" ;;
build)
  q -c "DROP INDEX IF EXISTS hn_d"
  r=$(one "SET maintenance_work_mem = '$MWM'; CREATE INDEX hn_d ON hn USING fts (d)")
  log "build rc/ms/peak_mib: $r size=$(q -c "SELECT pg_size_pretty(pg_relation_size('hn_d'))")" ;;
check)
  for t in rust postgres people; do
    a=$(q -c "SET enable_seqscan = off" -c "SELECT count(*) FROM hn WHERE d @@@ to_ftsquery('english', '$t')" | tail -1)
    b=$(q -c "SET enable_indexscan = off" -c "SET enable_bitmapscan = off" \
          -c "SELECT count(*) FROM hn WHERE fts_match(d, to_ftsquery('english', '$t'))" | tail -1)
    log "check $t index=$a heap=$b"
    [ "$a" = "$b" ] && [ "${a:-0}" -gt 0 ] || { log "CHECK FAILED for $t"; exit 1; }
  done ;;
trace)
  : > "$OUT/trace.tsv"
  n=0
  while IFS=$'\t' read -r band form sql; do
    n=$((n + 1))
    r=$(one "$sql")
    printf '%s\t%s\t%s\t%s\n' "$n" "$band" "$form" "$(echo "$r" | cut -d' ' -f1-3 | tr ' ' '\t')" >> "$OUT/trace.tsv"
    case $r in 0\ *) ;; *) echo "$n ${r#* * * }" >> "$OUT/trace_errors.txt" ;; esac
  done < "$TRACE"
  log "trace $n statements; errors $(awk -F'\t' '$4 != 0' "$OUT/trace.tsv" | wc -l)"
  awk -F'\t' '{k=$2"/"$3; c[k]++; if ($4!=0) e[k]++; if ($6>m[k]) m[k]=$6} END {for (k in c) printf "  %-16s n=%d errors=%d max_peak_mib=%d\n", k, c[k], e[k], m[k]}' \
    "$OUT/trace.tsv" | sort | tee -a "$OUT/run.log" ;;
conc)
  grep -P '\tfilter\t' "$TRACE" | cut -f3 > "$OUT/conc.sql"
  log "conc clients=$CLIENTS statements=$(wc -l < "$OUT/conc.sql")"
  for c in $(seq 1 "$CLIENTS"); do
    ( fails=0; ok=0
      while read -r sql; do
        if psql -X -q -At -c "$sql" > /dev/null 2>> "$OUT/conc_$c.err"; then ok=$((ok + 1)); else fails=$((fails + 1)); fi
      done < "$OUT/conc.sql"
      echo "client $c ok=$ok failed=$fails" >> "$OUT/conc.txt" ) &
  done
  wait
  log "conc $(awk '{o+=substr($3,4); f+=substr($4,8)} END {print "ok=" o, "failed=" f}' "$OUT/conc.txt")"
  sort "$OUT"/conc_*.err | uniq -c | sort -rn | head -5 | tee -a "$OUT/run.log" ;;
*) log "unknown phase $ph"; exit 2 ;;
esac; done
log HN_SCALE_DONE
