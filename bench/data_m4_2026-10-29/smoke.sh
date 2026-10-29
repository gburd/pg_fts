#!/bin/bash
# smoke: first ~200 MB of Posts.xml from the partial download is not decompressible; instead synthesize posts.tsv from
# a downloaded small site (superuser? no) -- use the Wikipedia-free path: generate 20k fake posts from /usr/share/dict-like
# text so every query kind and engine runs end to end on the real harness.  Output dir /nvme/m4smoke.
set -uo pipefail
S=/nvme/m4smoke; mkdir -p $S/se
python3 - <<'PY'
import random
rng=random.Random(7)
W=("postgres index query table select join error install python java string array function class method value null "
   "file server client request response database column row update delete insert key error message type list map "
   "thread memory performance build test version package module import return loop condition variable object").split()
with open('/nvme/m4smoke/se/posts.tsv','w') as o:
    for i in range(1,20001):
        n=rng.randint(20,200); o.write(f"{i}\tt{i}\t{' '.join(rng.choice(W) for _ in range(n))}\n")
PY
python3 - <<'PY'
import random
rng=random.Random(9); lines=open('/nvme/m4smoke/se/posts.tsv').read().split('\n')[:-1]
q=open('/nvme/m4smoke/se/queries.tsv','w'); qid=0
for _ in range(30):
    w=rng.choice(lines).split('\t')[2].split(); L=rng.randint(2,5); s=rng.randrange(0,len(w)-L)
    for kind in ('and','or','phrase'):
        qid+=1; q.write(f"{qid}\t{kind}\t{' '.join(w[s:s+L])}\n")
PY
sed -e "s#W=/nvme/m4; #W=/nvme/m4smoke/w; #" -e "s#SE=/nvme/se#SE=/nvme/m4smoke/se#" -e 's/-T 60 \$args/-T 5 $args/' -e 's/-T \$S -l/-T 10 -l/' -e 's/-R 1000 -T 600/-R 100 -T 15/' -e 's/-c 16 -j 8 -T 600 -l/-c 16 -j 8 -T 15 -l/' /tmp/m4/m4.sh > /tmp/m4/m4smoke.sh
bash /tmp/m4/m4smoke.sh base
for e in fts pdb pgts gin; do bash /tmp/m4/m4smoke.sh engine $e; done
echo SMOKE_DONE
