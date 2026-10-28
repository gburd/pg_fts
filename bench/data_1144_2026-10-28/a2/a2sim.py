# A2 offline: how much would a tighter per-block conjunctive bound save on a 2-term AND?
# Rebuilds both terms' posting lists in docid order (as pg_fts writes them: heap TID order),
# cuts the DRIVER (rarer term) into 128-posting blocks, and for each driver block computes
#   cur  = driver block bound + max bound of the other term's blocks overlapping its range
#          (fts_search_and_bestfirst, 1.11.0)
#   pair = max over the docs in the driver block that hold BOTH terms of
#          (driver term's block bound + other term's block bound for the block holding it),
#          i.e. a bound computed only over co-occurring docs (needs a per-pair index: unbuildable
#          at query time without reading the postings -- an upper limit on what a tighter
#          bound could buy)
#   best = max exact score in the block (the ideal: no bound is tighter)
# and counts driver blocks the best-first walk visits under each bound before the k-th score
# stops it.  Scores: pg_fts BM25 (k1 1.2, b 0.75), quantized doclen, N/avgdl from the index.
import subprocess, sys, math, json, heapq, bisect
P=["/nvme/rm/pfx17-wk/bin/psql","-h","/tmp","-p","6317","-U","postgres","-X","-q","-At","-F","\t"]
def q(sql): return subprocess.run(P+["-c",sql],capture_output=True,text=True,check=True).stdout
def q8(b):
    if b==0: return 0
    if b<=7: return b
    hb=b.bit_length()-1; e=hb-3; mant=(b>>e)&7; ee=e+1
    if ee>31: ee,mant=31,7
    byte=(ee<<3)|mant
    m=byte&7; ex=(byte>>3)&31
    return m if ex==0 else (8|m)<<(ex-1)
st=q("SELECT ndocs, avgdl FROM fts_index_stats('docs_fts')").strip().split("\t"); N=float(st[0]); avgdl=float(st[1])
k1,b=1.2,0.75
def score(tf,dl,idf): return idf*tf*(k1+1)/(tf+k1*(1-b+b*dl/avgdl))
def postings(term):
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
                      (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    return [tuple(int(x) if x else 0 for x in l.split("\t")) for l in rows.strip().split("\n") if l]
def blocks(post, idf):
    out=[]
    for i in range(0,len(post),128):
        blk=post[i:i+128]; T=max(t for _,t,_ in blk)
        x=math.floor(T*min(q8(d)/t for _,t,d in blk))
        ex=max(score(t,q8(dl),idf) for _,t,dl in blk)   # exact per-term block max (Pareto set)
        out.append((blk[0][0], blk[-1][0], score(T,q8(x),idf), i, ex))
    return out
a,bt=sys.argv[1],sys.argv[2]; K=[int(x) for x in (sys.argv[3:] or ["10"])]
pa,pb=postings(a),postings(bt)
if len(pa)>len(pb): a,bt,pa,pb=bt,a,pb,pa
ia=math.log(1+(N-len(pa)+0.5)/(len(pa)+0.5)); ib=math.log(1+(N-len(pb)+0.5)/(len(pb)+0.5))
ba,bb=blocks(pa,ia),blocks(pb,ib)
db={d:(t,dl) for d,t,dl in pb}
bfirst=[x[0] for x in bb]
def bblk(d): return bisect.bisect_right(bfirst,d)-1
inter=sorted(((score(t,q8(dl),ia)+score(db[d][0],q8(db[d][1]),ib)) for d,t,dl in pa if d in db), reverse=True)
res={"driver":a,"df_driver":len(pa),"other":bt,"df_other":len(pb),"intersection":len(inter),"driver_blocks":len(ba),"other_blocks":len(bb)}
cur=[];pair=[];best=[];texact=[]
for (lo,hi,bd,i0,exa) in ba:
    j0=max(0,bisect.bisect_right(bfirst,lo)-1); j1=bisect.bisect_right(bfirst,hi)
    mb=max((bb[j][2] for j in range(j0,j1) if bb[j][1]>=lo), default=-1)
    cur.append(bd+mb if mb>=0 else -1)
    mbx=max((bb[j][4] for j in range(j0,j1) if bb[j][1]>=lo), default=-1)
    texact.append(exa+mbx if mbx>=0 else -1)
    blk=pa[i0:i0+128]
    co=[(d,t,dl) for d,t,dl in blk if d in db]
    pair.append(max((bd+bb[bblk(d)][2] for d,_,_ in co), default=-1))
    best.append(max((score(t,q8(dl),ia)+score(db[d][0],q8(db[d][1]),ib) for d,t,dl in co), default=-1))
def walk(bound,k):
    order=sorted(range(len(ba)), key=lambda i:-bound[i]); h=[]; vis=0
    for i in order:
        if bound[i]<0 or (len(h)==k and bound[i]<h[0]): break
        vis+=1
        for s in [score(t,q8(dl),ia)+score(db[d][0],q8(db[d][1]),ib) for d,t,dl in pa[ba[i][3]:ba[i][3]+128] if d in db]:
            if len(h)<k: heapq.heappush(h,s)
            elif s>h[0]: heapq.heapreplace(h,s)
    return vis, sorted(h,reverse=True)==inter[:k]
for k in K:
    res[f"k{k}"]={nm:dict(zip(("visited","exact"),walk(bd,k))) for nm,bd in (("cur",cur),("term_exact",texact),("pair",pair),("best",best))}
    res[f"k{k}"]["thr"]=round(inter[k-1],4)
# how loose: median ratio cur/best over live blocks
live=[(c,p,bs) for c,p,bs in zip(cur,pair,best) if bs>0]
live.sort(key=lambda x:x[0]/x[2])
res["median_cur_over_best"]=round(live[len(live)//2][0]/live[len(live)//2][2],3) if live else None
print(json.dumps(res))
