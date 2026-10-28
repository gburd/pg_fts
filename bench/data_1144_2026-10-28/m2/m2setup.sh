#!/bin/bash
# M2 setup: BEIR scifact + nfcorpus (corpus, queries, test qrels) as TSV, and the pg_search 0.26.1 deb (PG17, amd64)
set -uo pipefail
exec > /nvme/m2/setup.log 2>&1
cd /nvme/m2
cat > beir.py <<'PY'
import os, pyarrow.parquet as pq
from huggingface_hub import hf_hub_download
def clean(x): return (x or "").replace("\t"," ").replace("\n"," ").replace("\r"," ").replace("\\"," ")
for ds in ("scifact","nfcorpus"):
    os.makedirs(ds, exist_ok=True)
    corp=pq.read_table(hf_hub_download(f"BeIR/{ds}", "corpus/corpus-00000-of-00001.parquet", repo_type="dataset", cache_dir="/nvme/hf")).to_pylist()
    qs=pq.read_table(hf_hub_download(f"BeIR/{ds}", "queries/queries-00000-of-00001.parquet", repo_type="dataset", cache_dir="/nvme/hf")).to_pylist()
    qr=hf_hub_download(f"BeIR/{ds}-qrels", "test.tsv", repo_type="dataset", cache_dir="/nvme/hf")
    with open(f"{ds}/docs.tsv","w") as o:
        for d in corp: o.write(f"{clean(d['_id'])}\t{clean(d.get('title'))}\t{clean(d.get('text'))}\n")
    with open(f"{ds}/queries.tsv","w") as o:
        for d in qs: o.write(f"{clean(d['_id'])}\t{clean(d['text'])}\n")
    with open(qr) as f, open(f"{ds}/qrels.tsv","w") as o:
        next(f)
        for l in f: o.write(l)
    print(ds, "docs", len(corp), "queries", len(qs), "qrels", sum(1 for _ in open(f"{ds}/qrels.tsv")))
PY
/nvme/venv/bin/python3 beir.py
md5sum scifact/*.tsv nfcorpus/*.tsv
# pg_search deb
V=0.26.1
[ -f postgresql-17-pg-search_${V}-1PARADEDB-trixie_amd64.deb ] || for name in postgresql-17-pg-search_${V}-1PARADEDB-trixie_amd64.deb; do
  curl -sfLO https://github.com/paradedb/paradedb/releases/download/v${V}/$name && echo "got $name $(sha256sum $name | cut -c1-16)" || echo "MISSING $name"
done
ls -la *.deb 2>/dev/null
echo M2SETUP_DONE
