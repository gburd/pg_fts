#!/usr/bin/env python3
"""analyze.py <data_dir> -- tables for PROTOCOL_FIELD_METAL_2026-11-19.md.

<data_dir>/<host>/<major>/{latency,tps,cold,gate,agree}.txt and <host>/<major>/run.log, with hosts named
x1 x2 (x86_64) and a1 a2 (aarch64).  Latency per (host, major, arm, band) = the median of the pass-medians,
with the pass min-max.  pg_fts vs each engine: ratio of medians (engine / pg_fts, so > 1 means pg_fts is
faster) with a bootstrap 95% CI over both hosts' pass-medians, and a verdict:
  STABLE   the two arms' pass spreads separate on both hosts and |effect| > 3x the A/A spread;
  NOISY    they separate on one host only;
  NO CLAIM otherwise.
The A/A spread for a band is max over hosts of |median(fts) - median(fts_aa)| / median(fts).
"""
import os
import random
import re
import statistics
import sys

D = sys.argv[1]
ARCH = {'x86_64': ['x1', 'x2'], 'aarch64': ['a1', 'a2']}
BANDS = ['rare_k10', 'mid_k10', 'common_k10', 'common_k100', 'common_k1000', 'or2_k10', 'or4_k10',
         'and_k10', 'and_us_k10', 'and_ww_k10', 'not_k10', 'phrase_us_k10', 'phrase_ww_k10', 'count_common']
CTE = {'and_k10', 'and_us_k10', 'and_ww_k10', 'not_k10', 'phrase_us_k10', 'phrase_ww_k10'}
ENGINES = {18: ['pgts_rel', 'pgts_main', 'psearch', 'psearch_pn', 'vchord', 'gin'], 19: ['pgts_main', 'gin']}
NAME = {'fts': 'pg_fts 1.18.0', 'pgts_rel': 'pg_textsearch 1.5.1', 'pgts_main': 'pg_textsearch main',
        'psearch': 'pg_search 0.27.0', 'psearch_pn': 'pg_search 0.27.0 pnorms', 'vchord': 'VectorChord-bm25 0.3.0',
        'gin': 'GIN + ts_rank'}


def load_lat(h, m):
    """{(arm, band): [pass medians]} and {(arm, band): 'TIMEOUT'|'ERROR'}"""
    p = f'{D}/{h}/{m}/latency.txt'
    vals, flags = {}, {}
    if not os.path.exists(p):
        return vals, flags
    for line in open(p):
        r = re.match(r'pass=(\d+) arm=(\S+) band=(\S+) rows=(\S*) median_last5=(\S*)', line)
        if not r:
            continue
        a, b, rows, med = r.group(2), r.group(3), r.group(4), r.group(5)
        if rows.startswith('TIMEOUT'):
            flags[(a, b)] = 'TIMEOUT'
        elif rows == 'ERROR':
            flags[(a, b)] = 'ERROR'
        elif re.search(r'_k(\d+)', b) and rows != re.search(r'_k(\d+)', b).group(1) + ',':
            flags[(a, b)] = 'SHORT'  # protocol gate 2: a top-k band must return k rows
        elif med:
            vals.setdefault((a, b), []).append(float(med))
    return vals, flags


def best(vals, flags, a, b):
    """the engine's number for a band: for pg_textsearch the faster of the plain and CTE forms"""
    cands = []
    for bb in ([b, b + '_cte'] if a.startswith('pgts') and b in CTE else [b]):
        if (a, bb) in vals:
            cands.append((statistics.median(vals[(a, bb)]), bb))
    if cands:
        return min(cands)[1]
    for bb in ([b, b + '_cte'] if a.startswith('pgts') and b in CTE else [b]):
        if (a, bb) in flags:
            return None
    return None


def boot_ratio(x, y, n=10000, seed=1):
    """bootstrap 95% CI of median(y)/median(x)"""
    rnd = random.Random(seed)
    rs = []
    for _ in range(n):
        xs = [rnd.choice(x) for _ in x]
        ys = [rnd.choice(y) for _ in y]
        rs.append(statistics.median(ys) / statistics.median(xs))
    rs.sort()
    return rs[int(0.025 * n)], rs[int(0.975 * n)]


def fmt(v):
    return f'{v:.2f}' if v < 100 else f'{v:,.0f}'


def latency_tables(m):
    print(f'\n## Latency, PG {m} (ms; median of pass-medians [pass min-max] per host)\n')
    arms = ['fts'] + ENGINES[m]
    for arch, hosts in ARCH.items():
        L = {h: load_lat(h, m) for h in hosts}
        if not any(L[h][0] for h in hosts):
            continue
        print(f'### {arch}\n')
        print('| band | ' + ' | '.join(NAME[a] for a in arms) + ' |')
        print('|---' * (len(arms) + 1) + '|')
        for b in BANDS:
            row = [b]
            for a in arms:
                cell = []
                for h in hosts:
                    vals, flags = L[h]
                    bb = best(vals, flags, a, b)
                    if bb and (a, bb) in vals:
                        v = vals[(a, bb)]
                        cell.append(f'{fmt(statistics.median(v))} [{fmt(min(v))}-{fmt(max(v))}]' + (' cte' if bb.endswith('_cte') else ''))
                    elif any((a, x) in flags for x in (b, b + '_cte')):
                        fl = [flags.get((a, x)) for x in (b, b + '_cte')]
                        cell.append('>300 s' if 'TIMEOUT' in fl else ('short' if 'SHORT' in fl else 'error'))
                    else:
                        cell.append('n/a')
                row.append(' / '.join(cell))
            print('| ' + ' | '.join(row) + ' |')
        print()


def verdict_tables(m):
    print(f'\n## pg_fts vs each engine, PG {m}: engine/pg_fts ratio of medians, bootstrap 95% CI, verdict\n')
    for arch, hosts in ARCH.items():
        L = {h: load_lat(h, m) for h in hosts}
        if not all(L[h][0] for h in hosts):
            continue
        print(f'### {arch} (both hosts)\n')
        print('| band | A/A | ' + ' | '.join(NAME[a] for a in ENGINES[m]) + ' |')
        print('|---' * (len(ENGINES[m]) + 2) + '|')
        for b in BANDS:
            aa = []
            for h in hosts:
                v = L[h][0]
                if ('fts', b) in v and ('fts_aa', b) in v:
                    f, g = statistics.median(v[('fts', b)]), statistics.median(v[('fts_aa', b)])
                    aa.append(abs(g - f) / f)
            aamax = max(aa) if aa else float('nan')
            row = [b, f'{100 * aamax:.1f}%']
            for a in ENGINES[m]:
                xs, ys, sep = [], [], 0
                ok = True
                for h in hosts:
                    vals, flags = L[h]
                    bb = best(vals, flags, a, b)
                    if not bb or ('fts', b) not in vals or (a, bb) not in vals:
                        ok = False
                        break
                    x, y = vals[('fts', b)], vals[(a, bb)]
                    xs += x
                    ys += y
                    if max(x) < min(y) or max(y) < min(x):
                        sep += 1
                if not ok:
                    flagged = [L[h][1].get((a, x)) for h in hosts for x in (b, b + '_cte')]
                    row.append('>300 s' if 'TIMEOUT' in flagged else ('short' if 'SHORT' in flagged else 'n/a'))
                    continue
                r = statistics.median(ys) / statistics.median(xs)
                lo, hi = boot_ratio(xs, ys)
                eff = abs(r - 1)
                v = 'STABLE' if sep == 2 and eff > 3 * aamax else ('NOISY' if sep >= 1 else 'NO CLAIM')
                row.append(f'{r:.2f}x [{lo:.2f}-{hi:.2f}] {v}')
            print('| ' + ' | '.join(row) + ' |')
        print()


def tps_tables(m):
    print(f'\n## Settled throughput, PG {m} (tps; median of 2 passes per host; host1 / host2)\n')
    for arch, hosts in ARCH.items():
        T = {}
        for h in hosts:
            p = f'{D}/{h}/{m}/tps.txt'
            if not os.path.exists(p):
                continue
            for line in open(p):
                r = re.match(r'pass=(\d) arm=(\S+) band=(\S+) (.*)', line)
                if not r:
                    continue
                if 'SKIPPED' in line:
                    T.setdefault((h, r.group(2), r.group(3)), 'skipped')
                    continue
                vals = {int(k): float(v) for k, v in re.findall(r'c(\d+)=([0-9.]+)', r.group(4))}
                fails = sum(int(v) for v in re.findall(r'f\d+=(\d+)', r.group(4)))
                T.setdefault((h, r.group(2), r.group(3)), []).append((vals, fails))
        if not T:
            continue
        print(f'### {arch}\n')
        print('| arm | band | ' + ' | '.join(f'c{c}' for c in (1, 16, 64, 128, 256)) + ' | failed |')
        print('|---' * 8 + '|')
        for a in ['fts'] + ENGINES[m]:
            for b in ['rare_k10', 'common_k10', 'and_us_k10', 'and_us_k10_cte', 'count_common']:
                cells, failed, seen = [], 0, False
                for c in (1, 16, 64, 128, 256):
                    per = []
                    for h in hosts:
                        x = T.get((h, a, b))
                        if isinstance(x, list):
                            seen = True
                            ps = [p[0][c] for p in x if c in p[0]]
                            failed += sum(p[1] for p in x) if c == 1 else 0
                            per.append(f'{statistics.median(ps):,.0f}' if ps else '-')
                        elif x == 'skipped':
                            seen = True
                            per.append('skip')
                    cells.append(' / '.join(per))
                if seen:
                    print(f'| {NAME[a]} | {b} | ' + ' | '.join(cells) + f' | {failed} |')
        print()


def cold_tables(m):
    print(f'\n## Cold cache, PG {m} (ms, median of 5 per host; host1 / host2)\n')
    for arch, hosts in ARCH.items():
        C = {}
        for h in hosts:
            p = f'{D}/{h}/{m}/cold.txt'
            if not os.path.exists(p):
                continue
            for line in open(p):
                r = re.match(r'rep=\d+ arm=(\S+) band=(\S+) cold_ms=(\S+)', line)
                if r:
                    try:
                        C.setdefault((r.group(1), r.group(2)), {}).setdefault(h, []).append(float(r.group(3)))
                    except ValueError:
                        C.setdefault((r.group(1), r.group(2)), {}).setdefault(h, [])
        if not C:
            continue
        print(f'### {arch}\n')
        for (a, b), per in sorted(C.items()):
            print(f'- {NAME.get(a, a)} {b}: ' + ' / '.join(f'{statistics.median(v):.1f}' if v else 'skip' for h, v in sorted(per.items())))
        print()


def build_tables(m):
    print(f'\n## Build and size, PG {m}\n')
    for arch, hosts in ARCH.items():
        for h in hosts:
            p = f'{D}/{h}/{m}/run.log'
            if not os.path.exists(p):
                continue
            for line in open(p):
                if re.search(r'\] (build |fts_vacuum )', line):
                    print(f'- {h}: {line.strip()[23:]}')


def gate(m):
    print(f'\n## Gate, PG {m}: counts against the regex ground truth\n')
    for arch, hosts in ARCH.items():
        for h in hosts:
            p = f'{D}/{h}/{m}/gate.txt'
            if os.path.exists(p):
                print(f'- {h}: ' + '; '.join(line.strip() for line in open(p)))


for m in (18, 19):
    gate(m)
    latency_tables(m)
    verdict_tables(m)
    tps_tables(m)
    cold_tables(m)
    build_tables(m)
