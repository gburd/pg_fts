#!/usr/bin/env python3
"""Deterministic query trace for the HackerNews corpus (see hn_corpus.py).

Zishuo's field run (pg_fts 1.18.0, 150M HackerNews documents) used 3,762
queries we do not have; his example was a wide mixed disjunction,
    'firebase' | 'analytics' | 'i' | 'don' <-> 't' | 'think' | 'that'
which pulls in stopword-like terms with corpus-scale match sets.  This
trace reproduces that SHAPE from real HN text, so the scan paths those
queries exercise (the collect path for a bare filter, WAND for a ranked
top-k) are covered until his trace is available.

Words come from the newest HELD_OUT items of the corpus file (those items
are also in the corpus, so every query matches; this is a scale trace, not a
relevance set).  For each such item, words are taken in order; each query is
one of:
  or_k      k words OR'ed (k = 2..8), the field shape
  and_2     two adjacent words AND'ed
  phrase_2  two adjacent words as a phrase
Every query is emitted twice, as a bare filter (count) and as a ranked
top-10, because the two forms take different scan paths.  Output is one
`band<TAB>form<TAB>sql` line per query, sorted by a seeded RNG so a
prefix of the file is a fair sample.

usage: hn_queries.py CORPUS.tsv N_QUERIES OUT.tsv [TABLE] [COLUMN]
"""

import random
import re
import sys

HELD_OUT = 20000
SEED = 20261123
WORD = re.compile(r"[a-z]{1,20}")


def words_of(content):
    return WORD.findall(content.lower())


def lit(w):
    return "'" + w + "'"


def main():
    corpus, nq, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    table = sys.argv[4] if len(sys.argv) > 4 else "hn"
    col = sys.argv[5] if len(sys.argv) > 5 else "d"

    # The held-out items: the last HELD_OUT lines (a corpus file is in id
    # order, so these are the newest items of the tier).
    with open(corpus, encoding="utf-8") as f:
        tail = []
        for line in f:
            tail.append(line)
            if len(tail) > HELD_OUT:
                tail.pop(0)
    rng = random.Random(SEED)
    queries = []
    for line in tail:
        ws = words_of(line.split("\t", 1)[1])
        if len(ws) < 8:
            continue
        kind = rng.choice(("or", "or", "or", "and_2", "phrase_2"))
        start = rng.randrange(0, len(ws) - 7)
        if kind == "or":
            k = rng.randint(2, 8)
            q = " | ".join(lit(w) for w in ws[start : start + k])
            band = f"or_{k}"
        elif kind == "and_2":
            q = f"{lit(ws[start])} & {lit(ws[start + 1])}"
            band = "and_2"
        else:
            q = f"{lit(ws[start])} <-> {lit(ws[start + 1])}"
            band = "phrase_2"
        queries.append((band, q))
        if len(queries) == nq:
            break

    with open(out_path, "w", encoding="utf-8") as out:
        for band, q in queries:
            fq = f"to_ftsquery('english', $q${q}$q$)"
            out.write(
                f"{band}\tfilter\tSELECT count(*) FROM {table} WHERE {col} @@@ {fq}\n"
            )
            out.write(
                f"{band}\tranked\tSELECT id FROM {table} WHERE {col} @@@ {fq} "
                f"ORDER BY {col} <=> {fq} LIMIT 10\n"
            )
    print(f"{len(queries)} queries ({2 * len(queries)} statements) -> {out_path}")


if __name__ == "__main__":
    main()
