#!/bin/bash
# swap6.sh: control for the PG18 pure-OR difference -- run each cluster with each .so
set -uo pipefail
O=/nvme/iss/b6; cd $O
M=18
SOV=/nvme/iss/b6/so_v1142.so; SOF=/nvme/iss/b6/so_fix.so
cp /nvme/iss/pg18-v1142/lib/postgresql/pg_fts.so $SOV; cp /nvme/iss/pg18-fix/lib/postgresql/pg_fts.so $SOF
for L in v1142 fix; do for SO in v1142 fix; do
  P=/nvme/iss/pg$M-$L; PO=57; [ $L = fix ] && PO=58
  $P/bin/pg_ctl -D /nvme/iss/d$M-$L -w stop >/dev/null
  cp /nvme/iss/b6/so_$SO.so $P/lib/postgresql/pg_fts.so
  $P/bin/pg_ctl -D /nvme/iss/d$M-$L -l /nvme/iss/d$M-$L/log -w start >/dev/null
  for r in 1 2 3; do $P/bin/psql -X -h /tmp -p $PO$M -U postgres -d b6 -f swap6.sql > swap_c${L}_so${SO}_$r.out 2>&1; done
done
  # restore the cluster's own .so
  $P/bin/pg_ctl -D /nvme/iss/d$M-$L -w stop >/dev/null; cp /nvme/iss/b6/so_$L.so $P/lib/postgresql/pg_fts.so
  $P/bin/pg_ctl -D /nvme/iss/d$M-$L -l /nvme/iss/d$M-$L/log -w start >/dev/null
done
python3 - <<'PY'
import re,glob,statistics,collections
rows=collections.defaultdict(list)
for f in sorted(glob.glob('/nvme/iss/b6/swap_*.out')):
    k=f.rsplit('/',1)[1][5:-4]; cur=None
    for ln in open(f):
        m=re.match(r'TIMING (.*)',ln)
        if m: cur=m.group(1).strip(); continue
        m=re.match(r'Time: ([0-9.]+) ms',ln)
        if m and cur: rows[(cur,k)].append(float(m.group(1)))
print("PG18 swap control: cluster x .so")
for k in sorted(rows): v=rows[k]; print("%-26s %-22s n=%d median %.3f ms"%(k[0],k[1],len(v),statistics.median(v)))
PY
echo SWAP6_DONE
