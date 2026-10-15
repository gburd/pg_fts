import re, statistics, sys, os, glob
D='/tmp/kiwi/metal'
hosts=['mx1','mx2','ma1','ma2']
bands=['rare_k10','mid_k10','common_k10','common_k100','common_k1000','or2_k10','or4_k10','and_k10','and_us_k10','not_k10','phrase_us_k10','phrase_ww_k10','count_common']
def load(h):
    r={}
    for l in open(f'{D}/{h}/latency.txt'):
        m=re.match(r'pass=(\d) arm=(\S+) band=(\S+) rows=(.*?) median_last5=(\S*)',l)
        if not m: continue
        p,a,b,rows,med=m.groups()
        to='TIMEOUT' in rows
        v=None if (to or med=='') else float(med)
        r.setdefault((a,b),[]).append((int(p),v,to,rows.split(',')[0]))
    return r
data={h:load(h) for h in hosts}
def cell(h,a,b):
    xs=data[h].get((a,b),[])
    if not xs: return None
    if all(x[2] for x in xs): return ('TO',None,None)
    vals=[x[1] for x in xs if x[1] is not None]
    if not vals: return ('TO',None,None)
    return (statistics.median(vals),min(vals),max(vals))
def fmt(c):
    if c is None: return 'n/a'
    if c[0]=='TO': return '>300 s'
    m,lo,hi=c
    f=(lambda x: f'{x:.2f}' if x<10 else (f'{x:.1f}' if x<1000 else f'{x/1000:.1f} s'))
    return f'{f(m)} [{f(lo)}-{f(hi)}]'
for arch,hs in [('x86_64 c6id.metal',['mx1','mx2']),('aarch64 c7gd.metal',['ma1','ma2'])]:
    print(f'\n### {arch}\n')
    print('| band | '+' | '.join(f'pg_fts {h}' for h in hs)+' | '+' | '.join(f'pgts HEAD {h}' for h in hs)+' | '+' | '.join(f'pgts 1.5.1 {h}' for h in hs)+' |')
    print('|---|'+'---|'*6)
    for b in bands:
        row=[fmt(cell(h,'fts',b)) for h in hs]+[fmt(cell(h,'pgts_head',b)) for h in hs]+[fmt(cell(h,'pgts_rel',b)) for h in hs]
        print(f'| {b} | '+' | '.join(row)+' |')
        if b in ('and_k10','and_us_k10','not_k10','phrase_us_k10','phrase_ww_k10'):
            row=['']*2+[fmt(cell(h,'pgts_head',b+'_cte')) for h in hs]+[fmt(cell(h,'pgts_rel',b+'_cte')) for h in hs]
            print(f'| {b} (pgts CTE form) | '+' | '.join(row)+' |')
# rows check
print('\nrows per band (pass 1):')
for h in hosts:
    s=[]
    for (a,b),xs in sorted(data[h].items()):
        x=[y for y in xs if y[0]==1]
        if x: s.append(f'{a}:{b}={x[0][3]}')
    print(h, ' '.join(s)[:2000])
