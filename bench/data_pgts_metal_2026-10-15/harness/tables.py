import re, statistics
D='/tmp/kiwi/metal'
def lat(h):
    r={}
    for l in open(f'{D}/{h}/latency.txt'):
        m=re.match(r'pass=(\d) arm=(\S+) band=(\S+) rows=(.*?) median_last5=(\S*)',l)
        if not m: continue
        p,a,b,rows,med=m.groups()
        r.setdefault((a,b),[]).append(None if ('TIMEOUT' in rows or med=='') else float(med))
    return r
L={h:lat(h) for h in ['mx1','mx2','ma1','ma2']}
def c(h,a,b):
    xs=L[h].get((a,b))
    if not xs: return None
    v=[x for x in xs if x is not None]
    if not v: return 'TO'
    return (statistics.median(v),min(v),max(v))
def f(x):
    return f'{x:.2f}' if x<10 else (f'{x:.1f}' if x<1000 else f'{x/1000:,.1f} s')
def cell(h1,h2,a,b):
    a1,a2=c(h1,a,b),c(h2,a,b)
    if a1 is None: return 'n/a'
    if a1=='TO' and a2=='TO': return '>300 s'
    return f'{f(a1[0])} / {f(a2[0])}'
def overlap(h,b,x,y):
    p,q=c(h,x,b),c(h,y,b)
    if p in (None,'TO') or q in (None,'TO'): return False
    return not (p[2] < q[1] or q[2] < p[1])
names={'rare_k10':'rare `slovakia` k10','mid_k10':'mid `hungary` k10','common_k10':'common `year` k10','common_k100':'common k100','common_k1000':'common k1000',
'or2_k10':'OR `slovakia | hungary`','or4_k10':'OR `film | music | album | band`','and_k10':'AND `slovakia & hungary`','and_us_k10':'AND `united & states`',
'not_k10':'NOT `hungary & !slovakia`','phrase_us_k10':'phrase `"united states"`','phrase_ww_k10':'phrase `"world war"`','count_common':'exact count of `year`'}
for arch,(h1,h2) in [('x86_64, c6id.metal (Ice Lake, 128 vCPU)',('mx1','mx2')),('aarch64, c7gd.metal (Graviton3, 64 vCPU)',('ma1','ma2'))]:
    print(f'\n#### {arch} -- median ms, host 1 / host 2\n')
    print('| band | pg_fts 1.13.0 | pg_textsearch HEAD a5fdfeb1 | pg_textsearch 1.5.1 | called |')
    print('|---|---|---|---|---|')
    for b,n in names.items():
        fts=cell(h1,h2,'fts',b); ph=cell(h1,h2,'pgts_head',b); pr=cell(h1,h2,'pgts_rel',b)
        if b+'_cte' in [k[1] for k in L[h1]]:
            phc=cell(h1,h2,'pgts_head',b+'_cte'); prc=cell(h1,h2,'pgts_rel',b+'_cte')
            ph=f'{ph}; CTE form {phc}'; pr=f'{pr}; CTE form {prc}'
        # call: differ on both hosts?
        called='pg_fts faster'
        both_overlap = overlap(h1,b,'fts','pgts_head') or overlap(h2,b,'fts','pgts_head')
        fa=c(h1,'fts',b); pa=c(h1,'pgts_head',b)
        if both_overlap: called='no difference called (spreads overlap)'
        elif fa not in (None,'TO') and pa not in (None,'TO') and fa[0]>pa[0]: called='pg_textsearch faster'
        print(f'| {n} | {fts} | {ph} | {pr} | {called} |')
