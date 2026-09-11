#!/usr/bin/env bash
# C2: ingest throughput + the query-latency-vs-pending-list curve.
#
# Measures what a production user actually hits, which bulk-build timing does not show:
#   A) sustained INSERT rows/s into a LIVE index (pg_fts appends to a pending list)
#   B) how ranked query latency DEGRADES as that pending list grows between merges
#   C) the cost of the merge that drains it
#   D) DELETE + VACUUM cost on the same corpus
#
#   usage: ingest.sh <dsn> <engine-label> <out.json>
# Per-engine SQL comes from env vars so one script serves every engine:
#   ING_INSERT  -- inserts $N rows starting at id $BASE (uses :n and :base params)
#   ING_QUERY   -- a ranked top-10 query to time between batches
#   ING_MERGE   -- optional: drains the pending list (pg_fts: fts_merge)
set -uo pipefail
DSN="$1"; ENGINE="$2"; OUT="$3"
BATCH="${BATCH:-25000}"; NBATCH="${NBATCH:-8}"
Q() { psql "$DSN" -X -q -t -A -c "$1" 2>/dev/null; }

command -v psql >/dev/null || { echo "no psql" >&2; exit 1; }
Q 'SELECT 1' >/dev/null || { echo "cannot connect" >&2; exit 1; }
[ -n "${ING_INSERT:-}" ] || { echo "ING_INSERT unset" >&2; exit 1; }
[ -n "${ING_QUERY:-}" ]  || { echo "ING_QUERY unset" >&2; exit 1; }

# median of 5 timed runs of the ranked query, in ms
# Median of 5, measured by the SERVER via \timing, not by wrapping psql: wrapping the
# process folds ~10 ms of psql startup into every sample, which is what made an earlier
# version report a suspiciously flat "10.0 ms" for every batch regardless of state.
qlat() {
  printf '\\timing on\n%s\n%s\n%s\n%s\n%s\n' "$ING_QUERY" "$ING_QUERY" "$ING_QUERY" "$ING_QUERY" "$ING_QUERY" \
    | psql "$DSN" -X -q 2>/dev/null \
    | awk '/^Time:/ {gsub("ms","",$2); print $2}' | sort -n | awk 'NR==3 {printf "%.1f", $1}'
}

base=$(Q 'SELECT COALESCE(max(id),0) FROM docs')
echo "  $ENGINE start: rows=$(Q 'SELECT count(*) FROM docs') base_id=$base" >&2
ins_series=""; lat_series=""
for b in $(seq 1 "$NBATCH"); do
  # Substitute :n / :base textually.  psql -v does NOT expand a plain :var inside -c
  # (it needs :'var' quoting), so the first version of this script silently ran a
  # syntactically invalid INSERT every batch, inserted nothing, and reported an
  # impossible 6.5M rows/s -- it was timing a no-op.  Text substitution plus the
  # row-count check below makes that unrepresentable.
  sql=${ING_INSERT//:n/$BATCH}; sql=${sql//:base/$base}
  before=$(Q 'SELECT count(*) FROM docs')
  t0=$(date +%s.%N)
  psql "$DSN" -X -q -c "$sql" >/dev/null 2>&1
  t1=$(date +%s.%N)
  after=$(Q 'SELECT count(*) FROM docs')
  got=$((after - before))
  if [ "$got" -ne "$BATCH" ]; then
    echo "  !! $ENGINE batch $b inserted $got rows, expected $BATCH -- ABORTING" >&2
    psql "$DSN" -X -c "$sql" 2>&1 | tail -3 >&2
    exit 1
  fi
  secs=$(echo "$t1-$t0" | bc)
  rps=$(echo "scale=1; $BATCH/$secs" | bc)
  base=$((base + BATCH))
  lat=$(qlat)
  ins_series="${ins_series}${ins_series:+ }${b}:${rps}rps"
  lat_series="${lat_series}${lat_series:+ }${b}:${lat}ms"
  echo "  $ENGINE batch $b: ${rps} rows/s, ranked query ${lat} ms" >&2
done

merge_secs=""
if [ -n "${ING_MERGE:-}" ]; then
  t0=$(date +%s.%N); Q "$ING_MERGE" >/dev/null; t1=$(date +%s.%N)
  merge_secs=$(echo "scale=1; $t1-$t0" | bc)
  echo "  $ENGINE merge: ${merge_secs}s" >&2
fi
post_merge_lat=$(qlat)

{
  printf '{\n  "engine": "%s",\n  "batch_rows": %s,\n  "batches": %s,\n' "$ENGINE" "$BATCH" "$NBATCH"
  printf '  "insert_rows_per_sec": "%s",\n' "$ins_series"
  printf '  "ranked_latency_after_batch": "%s",\n' "$lat_series"
  printf '  "merge_secs": "%s",\n  "ranked_latency_post_merge_ms": "%s"\n}\n' "$merge_secs" "$post_merge_lat"
} > "$OUT"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT" \
  && echo "OK wrote+validated $OUT" || { echo "FATAL: $OUT does not parse" >&2; exit 1; }
