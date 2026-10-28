#!/bin/bash
# bench7.sh: I19a/I19b timings on the reporter's 400k corpus (setup7.sql), arms v1143 vs i19, PG17+PG18, 3 runs each
set -uo pipefail
O=/nvme/rm/b7; mkdir -p $O; cd $O
for M in 17 18; do for L in v1143 i19; do
  B=/nvme/rm/pfx$M-$L/bin; D=/nvme/rm/d$M-$L; P=61$M; [ $L = i19 ] && P=62$M
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  $B/dropdb -h /tmp -p $P -U postgres --if-exists b7 >/dev/null 2>&1; $B/createdb -h /tmp -p $P -U postgres b7
  echo "== PG$M $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) $($B/psql -X -At -h /tmp -p $P -U postgres -d b7 -c "CREATE EXTENSION pg_fts; SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"
  $B/psql -X -At -h /tmp -p $P -U postgres -d b7 -f setup7.sql > setup_${M}_$L.out 2>&1; tail -1 setup_${M}_$L.out
  for r in 1 2 3; do $B/psql -X -h /tmp -p $P -U postgres -d b7 -f run7.sql > run_${M}_${L}_$r.out 2>&1; done
  $B/pg_ctl -D $D -w stop >/dev/null
done; done
python3 - <<'PY'
import re,glob,statistics,collections,hashlib
rows=collections.defaultdict(list)
for f in sorted(glob.glob('/nvme/rm/b7/run_*.out')):
    _,M,L,r=f.rsplit('/',1)[1][:-4].split('_')
    t=open(f).read()
    corr=t.split('\\echo')[0] if False else t[t.index('CORRECTNESS'):t.index('ORACLE')]
    orac=t[t.index('ORACLE'):t.index('BUFFERS')].replace('ORACLE','CORRECTNESS').replace('SET\n','').replace('RESET\n','')
    print("%s %s run%s correctness md5 %s; oracle(bestfirst=off) md5 %s; same=%s"%(M,L,r,hashlib.md5(corr.encode()).hexdigest()[:8],hashlib.md5(orac.encode()).hexdigest()[:8], corr.strip()==orac.strip()))
    cur=None
    for ln in t.split('\n'):
        m=re.match(r'TIMING (.*)',ln)
        if m: cur=m.group(1).strip(); continue
        m=re.match(r'Time: ([0-9.]+) ms',ln)
        if m and cur: rows[(M,cur,L,r)].append(float(m.group(1)))
print("PG  query                              arm    run  n  median_ms  min_ms  max_ms")
for k in sorted(rows):
    v=rows[k]; print("%-3s %-34s %-6s %-4s %2d %9.3f %7.3f %7.3f"%(k[0],k[1],k[2],k[3],len(v),statistics.median(v),min(v),max(v)))
PY
echo BENCH7_DONE
