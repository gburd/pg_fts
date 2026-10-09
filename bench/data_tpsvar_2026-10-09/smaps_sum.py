import re,sys
cur=None; agg={}
for l in open(sys.argv[1]):
    m=re.match(r'^[0-9a-f]+-[0-9a-f]+ \S+ \S+ \S+ \S+\s*(.*)$', l)
    if m:
        n=m.group(1).strip()
        cur=('dsm' if 'PostgreSQL.' in n else 'mainshm' if ('SYSV' in n or n.startswith('/dev/zero') or 'anon_hugepage' in n) else 'anon' if n in ('','[heap]') else None)
        continue
    if cur:
        m=re.match(r'^(Rss|ShmemPmdMapped|AnonHugePages|Shared_Hugetlb|Private_Hugetlb):\s+(\d+) kB', l)
        if m: d=agg.setdefault(cur,{}); d[m.group(1)]=d.get(m.group(1),0)+int(m.group(2))
print(" ".join(k+":"+",".join(a+"="+str(v//1024)+"M" for a,v in sorted(d.items()) if v) for k,d in sorted(agg.items())))
