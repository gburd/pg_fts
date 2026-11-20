#!/usr/bin/env python3
"""agree_sum.py <data_dir> <major> -- per query and k: each engine's overlap with pg_fts and its
top-k score sum under the one common formula (fts_bm25), host x1 (the ids are identical on every
host for a given arm; the script checks that and reports any host that differs)."""
import re
import sys

D, M = sys.argv[1], sys.argv[2]
rows = {}
for h in ('x1', 'x2', 'a1', 'a2'):
    for line in open(f'{D}/{h}/{M}/agree.txt'):
        r = re.match(r'q=\[(.*)\] k=(\d+) arm=(\S+) ids_md5=(\S*) common_score_sum=(\S*) ids=(\S*)', line)
        if r:
            rows.setdefault((r.group(1), int(r.group(2)), r.group(3)), {})[h] = (r.group(5), r.group(6))
diff = [(k, h) for k, v in rows.items() for h in v if v[h][1] != v['x1'][1]]
print(f'hosts whose ids differ from x1: {diff if diff else "none"}\n')
arms = []
for k in rows:
    if k[2] not in arms:
        arms.append(k[2])
print('| query | k | ' + ' | '.join(arms) + ' |')
print('|---' * (len(arms) + 2) + '|')
for q in dict.fromkeys(k[0] for k in rows):
    for kk in (10, 100):
        ref = set(rows[(q, kk, 'fts')]['x1'][1].split(','))
        cells = []
        for a in arms:
            s, ids = rows[(q, kk, a)]['x1']
            ov = len(ref & set(ids.split(','))) if ids else 0
            cells.append(f'{s} ({ov}/{kk})')
        print(f'| {q} | {kk} | ' + ' | '.join(cells) + ' |')
