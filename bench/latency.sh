#!/usr/bin/env bash
# Warm ranked/count latency sampler for pg_fts phases.  Prewarms, then takes
# NSAMP \timing samples per band and prints median/p95/p99 (ms).  Bands: rare,
# mid, common ranked k10/k100, AND count, count(*), phrase-free feature set.
# Usage: latency.sh <dsn> <table> <col> <index> [NSAMP]
set -euo pipefail
DSN="${1:?dsn}"; TBL="${2:?}"; COL="${3:?}"; IDX="${4:?}"; NS="${5:-200}"

psql "$DSN" -X -q -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm" >/dev/null 2>&1 || true
psql "$DSN" -X -q -t -A -c \
  "SELECT sum(pg_prewarm(c.oid)) FROM pg_class c WHERE relname IN ('$TBL','$IDX')" >/dev/null 2>&1 || true

timeq() { # $1 = SQL -> one Time: ms
  psql "$DSN" -X -q -t -A -c "\timing on" -c "$1" 2>/dev/null \
    | sed -n 's/^Time: \([0-9.]*\).*/\1/p' | tail -1
}
cat > /tmp/_lat_stats.py <<'PY'
import sys,statistics
xs=[float(x) for x in sys.stdin.read().split() if x.strip()]
if not xs: print("NA NA NA 0"); sys.exit(0)
xs.sort(); n=len(xs)
def q(p):
    i=(n-1)*p; lo=int(i); hi=min(lo+1,n-1); return xs[lo]+(xs[hi]-xs[lo])*(i-lo)
print(f"{statistics.median(xs):.3f} {q(.95):.3f} {q(.99):.3f} {n}")
PY
stats() { python3 /tmp/_lat_stats.py; }

band() { # $1=name  $2=SQL
  local out=""
  for _ in $(seq 1 "$NS"); do out+="$(timeq "$2") "; done
  printf '%-14s %s\n' "$1" "$(echo "$out" | stats)"
}

RARE="SELECT id FROM $TBL WHERE $COL @@@ to_ftsquery('english','slovakia') ORDER BY $COL <=> to_ftsquery('english','slovakia') LIMIT 10"
MID="SELECT id FROM $TBL WHERE $COL @@@ to_ftsquery('english','hungary') ORDER BY $COL <=> to_ftsquery('english','hungary') LIMIT 10"
COM="SELECT id FROM $TBL WHERE $COL @@@ to_ftsquery('english','year') ORDER BY $COL <=> to_ftsquery('english','year') LIMIT 10"
COM100="SELECT id FROM $TBL WHERE $COL @@@ to_ftsquery('english','year') ORDER BY $COL <=> to_ftsquery('english','year') LIMIT 100"
ANDC="SELECT count(*) FROM $TBL WHERE $COL @@@ to_ftsquery('english','slovakia & hungary')"
CNT="SELECT count(*) FROM $TBL WHERE $COL @@@ to_ftsquery('english','year')"

echo "band           median   p95     p99     n   (ms, NSAMP=$NS)"
band rare_k10   "$RARE"
band mid_k10    "$MID"
band common_k10 "$COM"
band common_k100 "$COM100"
band and_count  "$ANDC"
band count_common "$CNT"
