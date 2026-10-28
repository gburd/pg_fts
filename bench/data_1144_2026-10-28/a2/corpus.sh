#!/bin/bash
# the 2,188,038-article Wikipedia corpus (pinned HF dataset), md5 must be f5939e85...; /nvme/c.tsv
set -uo pipefail
[ -d /nvme/venv ] || python3 -m venv /nvme/venv
/nvme/venv/bin/pip -q install pyarrow huggingface_hub
cat > /nvme/corpus.py <<'PY'
import sys, os, pyarrow.parquet as pq
from huggingface_hub import list_repo_files, hf_hub_download
REPO="wikimedia/wikipedia"; CONFIG="20231101.en"; N=int(os.environ.get("CORPUS_N") or "2188038")
files=sorted(f for f in list_repo_files(REPO, repo_type="dataset") if f.startswith(CONFIG+"/") and f.endswith(".parquet"))
out=open("/nvme/c.tsv","w",encoding="utf-8"); n=0
for f in files:
    p=hf_hub_download(REPO, f, repo_type="dataset", cache_dir="/nvme/hf")
    t=pq.read_table(p, columns=["id","title","text"])
    for i,ti,b in zip(t.column("id").to_pylist(), t.column("title").to_pylist(), t.column("text").to_pylist()):
        c=((ti or "")+" "+(b or "")).replace("\t"," ").replace("\n"," ").replace("\r"," ").replace("\\"," ")
        out.write(f"{i}\t{c}\n"); n+=1
        if n==N: break
    os.remove(os.path.realpath(p))
    if n==N: break
out.close(); print("ROWS", n)
PY
/nvme/venv/bin/python3 /nvme/corpus.py
m=$(md5sum /nvme/c.tsv | cut -c1-32); echo "corpus md5=$m rows=$(wc -l < /nvme/c.tsv)"
case $m in f5939e85*) echo CORPUS_OK ;; *) echo CORPUS_MD5_MISMATCH ;; esac
