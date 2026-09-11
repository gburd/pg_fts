#!/usr/bin/env bash
# Concurrent-throughput harness (ROADMAP C1).
#
# Measures tps + mean latency at 1/8/16/32 clients per query band using pgbench,
# then writes ONE json atomically.  The previous run's pg_fts arm was lost to a
# truncated json (940 bytes, no closing brace, no under_load key), so this builds
# the whole document in memory and writes it with a single redirect, then verifies
# it parses before declaring success.
#
#   usage: underload.sh <dsn> <engine-label> <out.json>
# Query text per band comes from BAND_<name> env vars so the same script serves
# every engine's SQL dialect.
set -uo pipefail
DSN="$1"; ENGINE="$2"; OUT="$3"
CLIENTS="${CLIENTS:-1 8 16 32}"
LOAD_SECS="${LOAD_SECS:-30}"
BANDS="${BANDS:-rare_k10 common_k10 count_common}"

command -v pgbench >/dev/null || { echo "pgbench not found" >&2; exit 1; }
psql "$DSN" -X -tAc 'SELECT 1' >/dev/null || { echo "cannot connect: $DSN" >&2; exit 1; }

tmpd=$(mktemp -d); trap 'find "$tmpd" -delete 2>/dev/null' EXIT
declare -A RESULT

for band in $BANDS; do
  var="BAND_${band}"
  sql="${!var:-}"
  [ -z "$sql" ] && { echo "skip $band (no $var)" >&2; continue; }
  printf '%s\n' "$sql" > "$tmpd/$band.sql"
  # sanity: the query must actually run and return a row
  if ! psql "$DSN" -X -tAf "$tmpd/$band.sql" >/dev/null 2>&1; then
    echo "skip $band (query failed)" >&2; continue
  fi
  series=""
  for c in $CLIENTS; do
    j=$c; [ "$c" -gt 8 ] && j=8
    o=$(pgbench "$DSN" -n -f "$tmpd/$band.sql" -c "$c" -j "$j" -T "$LOAD_SECS" 2>/dev/null)
    tps=$(printf '%s\n' "$o" | awk '/^tps =/ {print $3; exit}')
    lat=$(printf '%s\n' "$o" | awk '/^latency average/ {print $4; exit}')
    # A band that yields no tps did not run (extension missing, operator absent, ...).
    # Recording 0 would look like a measured result, so abandon the band loudly instead.
    if [ -z "$tps" ] || [ "$tps" = "0" ]; then
      echo "  !! $ENGINE $band c=$c produced NO tps -- band abandoned, not recorded" >&2
      printf '%s\n' "$o" | tail -3 >&2
      series=""
      break
    fi
    series="${series}${series:+ }${c}:${tps}tps/${lat}ms"
    echo "  $ENGINE $band c=$c -> ${tps}tps ${lat}ms" >&2
  done
  if [ -z "$series" ]; then
    echo "  skipping $band in output (no valid measurements)" >&2
    continue
  fi
  RESULT[$band]="$series"
done

# build the whole document, then write once
{
  printf '{\n  "engine": "%s",\n  "load_secs": %s,\n  "clients": "%s",\n  "under_load": {\n' \
    "$ENGINE" "$LOAD_SECS" "$CLIENTS"
  first=1
  for band in "${!RESULT[@]}"; do
    [ $first -eq 0 ] && printf ',\n'
    printf '    "%s": "%s"' "$band" "${RESULT[$band]}"
    first=0
  done
  printf '\n  }\n}\n'
} > "$OUT"

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT" \
  && echo "OK wrote+validated $OUT" \
  || { echo "FATAL: $OUT does not parse" >&2; exit 1; }
