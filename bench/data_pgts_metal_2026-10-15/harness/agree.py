import re
for h in ['mx1','ma1']:
    print('==',h)
    d={}
    for l in open(f'/tmp/kiwi/metal/{h}/agree.txt'):
        m=re.match(r'q=\[(.*?)\] k=(\d+) arm=(\S+) ids_md5=\S+ common_score_sum=(\S+) ids=(.*)',l.strip())
        if m: d[(m.group(1),int(m.group(2)),m.group(3))]=(float(m.group(4)) if m.group(4) else None, m.group(5).split(','))
    for q in ['slovakia','hungary','year','slovakia hungary','film music album band']:
        for k in (10,100):
            f=d.get((q,k,'fts')); p=d.get((q,k,'pgts_head')); r=d.get((q,k,'pgts_rel'))
            if not f or not p: continue
            ov=len(set(f[1])&set(p[1])); same_rel = (p[1]==r[1]) if r else None
            # rank correlation on shared ids
            sh=[i for i in f[1] if i in set(p[1])]
            import statistics
            if len(sh)>2:
                rf={i:n for n,i in enumerate(f[1])}; rp={i:n for n,i in enumerate(p[1])}
                xs=[rf[i] for i in sh]; ys=[rp[i] for i in sh]
                mx,my=statistics.mean(xs),statistics.mean(ys)
                num=sum((a-mx)*(b-my) for a,b in zip(xs,ys)); den=(sum((a-mx)**2 for a in xs)*sum((b-my)**2 for b in ys))**0.5
                rho=num/den if den else 1.0
            else: rho=float('nan')
            print(f"  [{q}] k={k}: overlap {ov}/{k}  rank-corr(shared) {rho:.3f}  common-formula score sum fts={f[0]} pgts={p[0]} (fts-pgts {f[0]-p[0]:+.4f})  head==1.5.1 ids: {same_rel}")
