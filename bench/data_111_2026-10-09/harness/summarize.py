# Summarize the 1.11.0 run: latency medians of pass-medians [spread], settled tps medians [min-max].
import re, statistics, glob, collections, os, sys
os.chdir(os.path.dirname(os.path.abspath(__file__)) + "/..")
def lat(path, key_arm=True):
    d = collections.defaultdict(list); rows = {}
    for f in path:
        for l in open(f):
            m = re.search(r"pass=\d+ (?:arm=(\S+) )?band=(\S+) rows=(\S*)(?: median_last5=([0-9.]+))?", l)
            if not m: continue
            arm, band, r, med = m.group(1) or "-", m.group(2), m.group(3), m.group(4)
            rows[(band, arm)] = r
            if med and "TIMEOUT" not in r: d[(band, arm)].append(float(med))
            elif "TIMEOUT" in r: d[(band, arm)].append(None)
    return d, rows
def fmt(v):
    v2 = [x for x in v if x is not None]
    if not v2: return ">300 s (timeout)"
    return f"{statistics.median(v2):.2f} [{min(v2):.2f}-{max(v2):.2f}]"
print("== pg_fts latency (rel / a)")
d, rows = lat(["fts/latency.txt"])
for band in dict.fromkeys(b for b, _ in d):
    print(f"{band:15s} rel {fmt(d[(band,'rel')]):22s} a {fmt(d[(band,'a')]):22s} rows={rows[(band,'rel')]}")
for e in ("pgts", "psearch", "vchord"):
    print(f"== {e} latency")
    d, rows = lat([f"{e}/latency.txt", f"{e}/latency_extra.txt"])
    for band in dict.fromkeys(b for b, _ in d):
        print(f"{band:15s} {fmt(d[(band,'-')]):22s} rows={rows[(band,'-')]}")
def tps(files):
    t = collections.defaultdict(list)
    for f in files:
        for l in open(f):
            m = re.search(r"band=(\S+) c16=([0-9.]+) c32=([0-9.]+) c64=([0-9.]+)", l)
            if m:
                for c, v in zip((16, 32, 64), m.groups()[1:]): t[(m.group(1), c)].append(float(v))
    return t
print("== settled tps (median [min-max] of all passes of both settled runs)")
for name, files in (("pg_fts rel", glob.glob("fts/tps_settled_rel_r*.txt")), ("pg_fts a", glob.glob("fts/tps_settled_a_r*.txt")),
                    ("pgts", glob.glob("pgts/tps_settled_r*.txt")), ("psearch", glob.glob("psearch/tps_settled_r*.txt")),
                    ("vchord", glob.glob("vchord/tps_settled_r*.txt"))):
    t = tps(files)
    for band in dict.fromkeys(b for b, _ in t):
        print(f"{name:11s} {band:13s} " + " / ".join(f"{statistics.median(t[(band,c)]):,.0f}" for c in (16, 32, 64))
              + "   [" + "; ".join(f"{min(t[(band,c)]):,.0f}-{max(t[(band,c)]):,.0f}" for c in (16, 32, 64)) + f"] n={len(t[(band,16)])}")
print("== in-run tps (lat3 / fts_111 in-run phase)")
for name, f in (("pg_fts", "fts/tps.txt"), ("pgts", "pgts/tps.txt"), ("psearch", "psearch/tps.txt"), ("vchord", "vchord/tps.txt")):
    for l in open(f): print(name, l.strip())
