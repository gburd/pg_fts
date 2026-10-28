# A2 offline, step 2: why the effective-length bound (max_tf, x) is loose for world/war, and
# what a stored Pareto frontier of (tf, dl) per block would cost.  For each 128-block:
#   frontier = (tf, quantized dl) pairs not dominated by another posting (higher-or-equal tf AND
#              lower-or-equal dl); the exact block max for ANY avgdl/idf is the max over these.
# Reports the frontier size distribution (bytes it would take in the block header) and, for
# world & war at k=10, driver blocks visited by best-first when each term's block bound is
#   cur:   score(max_tf, x)          (1.11.0, as stored)
#   fK:    max over the K highest-tf frontier points + score(max_tf, x) capped ... (approximation:
#          max over the first K frontier points, plus cur restricted to postings beyond them)
# The fK bound stays sound: points not stored are bounded by score(tf_K+1, x') where x' is the
# effective length of the remaining postings -- computed here exactly.
import subprocess, sys, math, json, heapq, bisect, collections
exec(open('/tmp/rm/a2sim.py').read().split("a,bt=sys.argv[1],sys.argv[2]")[0])
def frontier(blk):
    pts=sorted({(t,q8(dl)) for _,t,dl in blk}, key=lambda p:(-p[0],p[1]))
    out=[]; best=None
    for t,d in pts:
        if best is None or d<best: out.append((t,d)); best=d
    return out
def kbound(blk, idf, K):
    # sound bound using K stored frontier points + an effective-length bound on the rest
    fr=frontier(blk); stored=fr[:K]
    m=max((score(t,d,idf) for t,d in stored), default=-1)
    rest=[(t,dl) for _,t,dl in blk if not any(t<=st and q8(dl)>=sd for st,sd in stored)]
    if rest:
        T=max(t for t,_ in rest); x=math.floor(T*min(q8(dl)/t for t,dl in rest))
        m=max(m, score(T,q8(x),idf))
    return m
a,bt=sys.argv[1],sys.argv[2]; KS=[1,2,4,8]
pa,pb=postings(a),postings(bt)
if len(pa)>len(pb): a,bt,pa,pb=bt,a,pb,pa
ia=math.log(1+(N-len(pa)+0.5)/(len(pa)+0.5)); ib=math.log(1+(N-len(pb)+0.5)/(len(pb)+0.5))
db={d:(t,dl) for d,t,dl in pb}
inter=sorted(((score(t,q8(dl),ia)+score(db[d][0],q8(db[d][1]),ib)) for d,t,dl in pa if d in db), reverse=True)
def blks(post): return [post[i:i+128] for i in range(0,len(post),128)]
A=blks(pa); B=blks(pb); bfirst=[b[0][0] for b in B]
fsz=collections.Counter(len(frontier(b)) for b in A+B)
res={"driver":a,"other":bt,"frontier_size_hist":dict(sorted(fsz.items())[:20]),"frontier_size_p50":sorted(len(frontier(b)) for b in A+B)[len(A+B)//2],"frontier_size_p90":sorted(len(frontier(b)) for b in A+B)[int(len(A+B)*.9)]}
def walk(bA, bB, k):
    bound=[]
    for i,blk in enumerate(A):
        lo=blk[0][0]; hi=A[i+1][0][0] if i+1<len(A) else 1<<62
        j0=max(0,bisect.bisect_right(bfirst,lo)-1); j1=bisect.bisect_left(bfirst,hi)
        mb=max((bB[j] for j in range(j0,max(j1,j0+1)) if B[j][-1][0]>=lo), default=-1)
        bound.append(bA[i]+mb if mb>=0 else -1)
    order=sorted(range(len(A)), key=lambda i:-bound[i]); h=[]; vis=0
    for i in order:
        if bound[i]<0 or (len(h)==k and bound[i]<h[0]): break
        vis+=1
        for d,t,dl in A[i]:
            if d in db:
                s=score(t,q8(dl),ia)+score(db[d][0],q8(db[d][1]),ib)
                if len(h)<k: heapq.heappush(h,s)
                elif s>h[0]: heapq.heapreplace(h,s)
    return vis, sorted(h,reverse=True)==inter[:k]
for K in KS:
    bA=[kbound(b,ia,K) for b in A]; bB=[kbound(b,ib,K) for b in B]
    v,ok=walk(bA,bB,10); res[f"stored_{K}_k10"]={"visited":v,"exact":ok}
bA=[kbound(b,ia,0) for b in A]; bB=[kbound(b,ib,0) for b in B]
v,ok=walk(bA,bB,10); res["stored_0_k10(=cur)"]={"visited":v,"exact":ok}
print(json.dumps(res))
