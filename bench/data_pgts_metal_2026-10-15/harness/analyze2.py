import re, statistics
D='/tmp/kiwi/metal'
hosts=['mx1','mx2','ma1','ma2']
print("## TPS (settled; median of 2 passes; c1/16/64/128/256)")
for h in hosts:
    t={}
    for l in open(f'{D}/{h}/tps.txt'):
        m=re.match(r'pass=(\d) arm=(\S+) band=(\S+) (.*)',l)
        if not m or 'SKIPPED' in l: continue
        vals=dict(re.findall(r'c(\d+)=([0-9.]+)',m.group(4)))
        t.setdefault((m.group(2),m.group(3)),[]).append({int(k):float(v) for k,v in vals.items()})
    print(f"### {h}")
    for (a,b),ps in sorted(t.items()):
        cs=sorted(ps[0].keys())
        med={c:statistics.median([p[c] for p in ps if c in p]) for c in cs}
        spread={c:(min(p[c] for p in ps), max(p[c] for p in ps)) for c in cs}
        print(f"  {a:10s} {b:14s} "+"  ".join(f"c{c}={med[c]:,.0f}" for c in cs)+f"   (passes={len(ps)})")
print("\n## Cold (median of 5, ms)")
for h in hosts:
    c={}
    for l in open(f'{D}/{h}/cold.txt'):
        m=re.match(r'rep=(\d) arm=(\S+) band=(\S+) cold_ms=(\S+)',l)
        if m:
            try: c.setdefault((m.group(2),m.group(3)),[]).append(float(m.group(4)))
            except: c.setdefault((m.group(2),m.group(3)),[]).append(m.group(4))
    print(f"### {h}: "+"; ".join(f"{a}:{b}={statistics.median([x for x in v if isinstance(x,float)]) if any(isinstance(x,float) for x in v) else v[0]}" for (a,b),v in sorted(c.items())))
print("\n## Build / size")
for h in hosts:
    for l in open(f'{D}/{h}/run.log'):
        if ' build ' in l or 'fts_vacuum' in l: print(h, l.strip()[22:])
print("\n## Host state")
for h in hosts:
    for l in open(f'{D}/{h}/run.log'):
        if 'hoststate' in l: print(h, re.sub(r'\(AnonHuge.*?\)','',l.strip()[22:])[:120])
    for l in open(f'{D}/{h}/run.log'):
        if l[22:].startswith('host ') or l[22:].startswith('os '): print(h, l.strip()[22:])
