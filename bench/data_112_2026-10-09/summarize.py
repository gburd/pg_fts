# I7 A/B summary: latency median of pass-medians (rel -> i7, % change; * = spreads do not overlap)
# and throughput (median of the 6 rel and 6 i7 points per host, same marking).
import re, collections, statistics, glob, os, sys
os.chdir(os.path.dirname(os.path.abspath(__file__)))
def mark(r, a):
    return "" if max(min(r), min(a)) <= min(max(r), max(a)) else "*"
for h in sorted(glob.glob("f[0-9]")):
    log = open(f"{h}/run.log").read()
    st = re.findall(r"mbench2 (before|after): chase  1024 MiB 4k  : ([0-9.]+)", log)
    print(f"== {h}  1 GiB 4k chase: " + " ".join(f"{a}={b}" for a, b in st))
    d = collections.defaultdict(list)
    if os.path.exists(f"{h}/latency.txt"):
        for l in open(f"{h}/latency.txt"):
            m = re.search(r"arm=(\S+) band=(\S+) median_last5=([0-9.]+)", l)
            if m: d[(m.group(2), m.group(1))].append(float(m.group(3)))
        print("  latency ms: " + "  ".join(
            f"{b} {statistics.median(d[(b,'rel')]):.2f}->{statistics.median(d[(b,'i7')]):.2f} ({100*(statistics.median(d[(b,'i7')])/statistics.median(d[(b,'rel')])-1):+.0f}%{mark(d[(b,'rel')], d[(b,'i7')])})"
            for b in dict.fromkeys(k[0] for k in d)))
    t = collections.defaultdict(list)
    for m in re.finditer(r"arm=(\S+) (rare c16=.*)", log):
        arm = m.group(1)
        for k, v in re.findall(r"(\w+ c\d+|c\d+)=(\d+)", m.group(2)):
            pass
        # parse "rare c16=X c64=Y mid c16=.. "
        toks = m.group(2).split(); band = None
        for tok in toks:
            if "=" in tok:
                c, v = tok.split("="); t[(band, c, arm)].append(int(v))
            else:
                band = tok
    if t:
        keys = list(dict.fromkeys((b, c) for b, c, _ in t))
        print("  tps: " + "  ".join(
            f"{b} {c} {statistics.median(t[(b,c,'rel')]):.0f}->{statistics.median(t[(b,c,'i7')]):.0f} ({100*(statistics.median(t[(b,c,'i7')])/statistics.median(t[(b,c,'rel')])-1):+.1f}%{mark(t[(b,c,'rel')], t[(b,c,'i7')])})"
            for b, c in keys))
