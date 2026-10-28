#!/bin/bash
# bench6.sh: #6 timings, arms v1142 (port 57xx) and fix (58xx), PG17+PG18, 3 runs each arm, same corpus
set -uo pipefail
O=/nvme/iss/b6; mkdir -p $O; cd $O
for M in 17 18; do for L in v1142 fix; do
  P=/nvme/iss/pg$M-$L/bin; PO=57; [ $L = fix ] && PO=58
  $P/dropdb -h /tmp -p $PO$M -U postgres --if-exists b6 >/dev/null 2>&1; $P/createdb -h /tmp -p $PO$M -U postgres b6
  echo "== PG$M $L $($P/psql -X -At -h /tmp -p $PO$M -U postgres -d b6 -c "CREATE EXTENSION pg_fts; SELECT extversion FROM pg_extension WHERE extname='pg_fts'") so=$(md5sum /nvme/iss/pg$M-$L/lib/postgresql/pg_fts.so | cut -c1-8)"
  $P/psql -X -At -h /tmp -p $PO$M -U postgres -d b6 -f setup6.sql > setup_${M}_$L.out 2>&1; tail -1 setup_${M}_$L.out
  for r in 1 2 3; do
    $P/psql -X -h /tmp -p $PO$M -U postgres -d b6 -f run6.sql > run_${M}_${L}_$r.out 2>&1
  done
done; done
python3 - <<'PY'
import re,glob,statistics,collections
rows=collections.defaultdict(list)
for f in sorted(glob.glob('/nvme/iss/b6/run_*.out')):
    _,M,L,r=f.rsplit('/',1)[1][:-4].split('_')
    cur=None
    for ln in open(f):
        m=re.match(r'TIMING (.*)',ln)
        if m: cur=m.group(1).strip(); continue
        m=re.match(r'Time: ([0-9.]+) ms',ln)
        if m and cur: rows[(M,cur,L,r)].append(float(m.group(1)))
print("PG  query                         arm    run  n  median_ms  min_ms  max_ms")
for k in sorted(rows):
    v=rows[k]; print("%-3s %-29s %-6s %-4s %2d %9.3f %7.3f %7.3f"%(k[0],k[1],k[2],k[3],len(v),statistics.median(v),min(v),max(v)))
PY
echo BENCH6_DONE
