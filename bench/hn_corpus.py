#!/usr/bin/env python3
"""Build a HackerNews text corpus for pg_fts tests and benchmarks.

Source: the open-index/hacker-news dataset on Hugging Face (ODC-BY 1.0), one
Parquet file per month of the HN API item stream.  The dataset is updated
every five minutes, so every build pins a dataset commit (REVISION below) and
the list of monthly files it reads.  The same revision and tier always produce
the same bytes; `hn_corpus.lock.json` records the revision, the file list with
sizes, the row counts and the md5 of the output.

One document is one HN item that is neither deleted nor dead and has text:
    content = title + ' ' + text
with HTML entities decoded and tags removed from `text` (comments and
Ask/Show HN bodies are HTML).  Tabs, newlines and backslashes become spaces,
so the output loads with COPY (FORMAT text) into (id bigint, content text).
Items are emitted in id order, which is the order HN created them.

The archive holds about 49M items, of which about 45M have text, so a corpus
larger than the archive is built by replication: copy k of item i gets the id
k * 100000000 + i and the same content.  Replication keeps the term
distribution and document lengths, and scales every term's df and every match
set by the replication factor.  That is what a scale test needs (index size,
build time and memory, match-set sizes of a wide filter).  It is NOT a
relevance corpus: copies tie in BM25 score.  The lock file records the factor.

usage: hn_corpus.py TIER OUTDIR
  TIER   one of: smoke (1 month), 1m, 10m, full, 150m
  OUTDIR receives hn_<tier>.tsv, hn_corpus.lock.json and a Parquet cache
"""

import hashlib
import html
import json
import os
import re
import sys

import pyarrow.parquet as pq
from huggingface_hub import HfApi, hf_hub_download

REPO = "open-index/hacker-news"
REVISION = "c54ced5973b95d80cd934b8921f44ec8d87c3cd1"  # 2026-08-23 snapshot
COPY_STRIDE = 100_000_000  # id offset per replica; HN ids are < 5e7
TIERS = {
    "smoke": None,
    "1m": 1_000_000,
    "10m": 10_000_000,
    "full": 0,
    "150m": 150_000_000,
}
SMOKE_FILE = "data/2015/2015-01.parquet"

TAG = re.compile(r"<[^>]+>")
SPACE = re.compile(r"[\t\n\r\\]+")


def clean(title, text):
    """One document's content, or '' when the item has no usable text."""
    body = html.unescape(TAG.sub(" ", text)) if text else ""
    s = ((title or "") + " " + body).strip()
    return SPACE.sub(" ", s)


def monthly_files():
    """The pinned revision's monthly Parquet files, oldest first, with sizes."""
    info = HfApi().dataset_info(REPO, revision=REVISION, files_metadata=True)
    files = sorted(
        (s.rfilename, s.size)
        for s in info.siblings
        if s.rfilename.startswith("data/") and s.rfilename.endswith(".parquet")
    )
    return files


def items(files, cache):
    """Yield (id, content) for every usable item, in file and row order."""
    for name, _size in files:
        path = hf_hub_download(
            REPO, name, repo_type="dataset", revision=REVISION, cache_dir=cache
        )
        t = pq.read_table(path, columns=["id", "deleted", "dead", "title", "text"])
        cols = [
            t.column(c).to_pylist() for c in ("id", "deleted", "dead", "title", "text")
        ]
        for i, deleted, dead, title, text in zip(*cols):
            if deleted or dead:
                continue
            content = clean(title, text)
            if content:
                yield i, content


def main():
    tier, outdir = sys.argv[1], sys.argv[2]
    if tier not in TIERS:
        sys.exit(f"unknown tier {tier!r}; choose one of {', '.join(TIERS)}")
    os.makedirs(outdir, exist_ok=True)
    cache = os.path.join(outdir, "hf")
    files = monthly_files()
    if tier == "smoke":
        files = [f for f in files if f[0] == SMOKE_FILE]
    target = TIERS[tier]
    out_path = os.path.join(outdir, f"hn_{tier}.tsv")

    # Copy 0 is the archive itself; a tier larger than the archive replays it
    # from the Parquet cache (copy k, k >= 1, offsets every id by k * stride)
    # until the target is reached.  Memory stays bounded by one month.
    md5 = hashlib.md5()
    n = 0
    base = 0
    copy = 0
    with open(out_path, "w", encoding="utf-8") as out:
        while True:
            for i, content in items(files, cache):
                if target and n == target:
                    break
                line = f"{copy * COPY_STRIDE + i}\t{content}\n"
                out.write(line)
                md5.update(line.encode("utf-8"))
                n += 1
            if copy == 0:
                base = n
            copy += 1
            if not target or n >= target or base == 0:
                break

    lock = {
        "dataset": REPO,
        "revision": REVISION,
        "license": "ODC-BY-1.0",
        "tier": tier,
        "rows": n,
        "distinct_items": base,
        "replication_factor": round(n / base, 4) if base else 0,
        "copy_id_stride": COPY_STRIDE,
        "files": [{"name": f, "size": s} for f, s in files],
        "output": os.path.basename(out_path),
        "md5": md5.hexdigest(),
    }
    with open(os.path.join(outdir, "hn_corpus.lock.json"), "w") as f:
        json.dump(lock, f, indent=1)
    print(f"ROWS {n} distinct {base} md5 {md5.hexdigest()}")


if __name__ == "__main__":
    main()
