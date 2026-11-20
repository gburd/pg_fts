#!/usr/bin/env python3
"""headline.py <data_dir> <major> -- compact latency table: per arm and band, the range over an
architecture's two hosts of each host's median of pass-medians, as 'x86 / arm'.  pg_textsearch's
AND/NOT/phrase cells use the faster of its plain and CTE forms, marked 'cte'."""
import importlib.util
import statistics
import sys

spec = importlib.util.spec_from_file_location('an', __file__.replace('headline.py', 'analyze.py'))
sys.argv = [sys.argv[0], sys.argv[1], sys.argv[2]]
M = int(sys.argv[2])
an = importlib.util.module_from_spec(spec)
src = open(spec.origin).read().split('\nfor m in (18, 19):')[0]
exec(compile(src, spec.origin, 'exec'), an.__dict__)


def rng(vals):
    lo, hi = min(vals), max(vals)
    f = an.fmt
    return f(lo) if f(lo) == f(hi) else f'{f(lo)}-{f(hi)}'


arms = ['fts'] + an.ENGINES[M]
print('| ms (x86 / arm) | ' + ' | '.join(an.NAME[a] for a in arms) + ' |')
print('|---' * (len(arms) + 1) + '|')
for b in an.BANDS:
    row = [b]
    for a in arms:
        per = []
        for hosts in an.ARCH.values():
            meds, tag, flag = [], '', None
            for h in hosts:
                vals, flags = an.load_lat(h, M)
                bb = an.best(vals, flags, a, b)
                if bb and (a, bb) in vals:
                    meds.append(statistics.median(vals[(a, bb)]))
                    tag = ' cte' if bb.endswith('_cte') else tag
                else:
                    flag = flags.get((a, b)) or flags.get((a, b + '_cte'))
            per.append(rng(meds) + tag if len(meds) == len(hosts) else {'TIMEOUT': '>300 s', 'SHORT': 'short'}.get(flag, 'n/a'))
        row.append(' / '.join(per))
    print('| ' + ' | '.join(row) + ' |')
