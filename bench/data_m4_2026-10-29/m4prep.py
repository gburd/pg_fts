#!/usr/bin/env python3
# m4prep.py: Stack Overflow posts (archive.org stackexchange 2024-04, stackoverflow.com-Posts.7z -> Posts.xml) to a TSV
# (id <TAB> title <TAB> body-as-text) and a synthetic query trace in the form TIN's article describes:
# substrings of 2-15 consecutive words sampled from documents, each used three ways (AND, OR, phrase).
# The article used 3,762 queries = 1,254 substrings; we sample 1,254 substrings with seed 20261029.
#   usage: 7z x -so stackoverflow.com.7z Posts.xml | python3 m4prep.py /nvme/se/posts.tsv /nvme/se/queries.tsv
import sys, re, html, random
from xml.etree.ElementTree import iterparse
out = open(sys.argv[1], "w", encoding="utf-8")
TAG = re.compile(r"<[^>]+>")
WS = re.compile(r"[\t\n\r\\]+")
WORD = re.compile(r"[a-z]+")
rng = random.Random(20261029)
NS, reservoir, n = 1254, [], 0
for ev, el in iterparse(sys.stdin.buffer, events=("end",)):
    if el.tag != "row":
        continue
    a = el.attrib
    if a.get("PostTypeId") in ("1", "2"):       # questions and answers only
        title = WS.sub(" ", a.get("Title", ""))
        body = WS.sub(" ", html.unescape(TAG.sub(" ", a.get("Body", ""))))
        out.write(f"{a['Id']}\t{title}\t{body}\n")
        n += 1
        # reservoir-sample documents for the query trace (only short-ish words a-z, so every
        # engine's parser sees plain words: no punctuation operators in any query language)
        if len(reservoir) < NS:
            reservoir.append(body)
        else:
            j = rng.randrange(n)
            if j < NS:
                reservoir[j] = body
    el.clear()
out.close()
q = open(sys.argv[2], "w", encoding="utf-8")
qid = 0
for body in reservoir:
    w = WORD.findall(body.lower())
    L = rng.randint(2, 15)
    if len(w) < L:
        L = max(2, len(w))
    if len(w) < 2:
        continue
    s = rng.randrange(0, len(w) - L + 1)
    words = w[s:s + L]
    for kind in ("and", "or", "phrase"):
        qid += 1
        q.write(f"{qid}\t{kind}\t{' '.join(words)}\n")
q.close()
print("docs", n, "queries", qid, file=sys.stderr)
