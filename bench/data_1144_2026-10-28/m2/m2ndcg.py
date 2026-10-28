#!/usr/bin/env python3
# M2: NDCG@10 / Recall@100 / MRR@10 on BEIR (scifact, nfcorpus), one PostgreSQL 17.10 cluster, three systems:
#   pgfts      -- pg_fts, to_ftsdoc('english', title || ' ' || text), query = OR of the query's
#                 to_ftsquery('english', word) terms, ORDER BY <=> (BM25), LIMIT 100
#   pgfts_simple -- the same with the 'simple' configuration (no stemming, no stopwords): what
#                 pg_fts ranks like when it does not stem, i.e. the unit of work pg_search does
#   pgsearch   -- pg_search 0.26.1, bm25 index on (id, title, body), default tokenizer, query =
#                 paradedb.match over title+body (disjunction of the query tokens), ORDER BY
#                 paradedb.score DESC, LIMIT 100
#   tsrank     -- built-in: to_tsvector('english') GIN, OR of terms, ORDER BY ts_rank DESC, LIMIT 100
# Query text is reduced to its alphanumeric words for every system (the same token set).
import sys, math, re, subprocess, collections, json
P=["/nvme/m2/pg/bin/psql","-h","/tmp","-p","6417","-U","postgres","-X","-q","-At","-F","\t"]
def q(db, sql): return subprocess.run(P+["-d",db,"-c",sql],capture_output=True,text=True).stdout
def words(t): return [w for w in re.findall(r"[A-Za-z0-9]+", t.lower()) if len(w) > 0]
def lit(s): return "'" + s.replace("'", "''") + "'"
def sql_for(system, text):
    ws = words(text)
    if not ws: return None
    if system in ("pgfts", "pgfts_simple"):
        cfg = "english" if system == "pgfts" else "simple"
        col = "d" if system == "pgfts" else "ds"
        # each word quoted: a bare and/or/not is a keyword operator in the ftsquery
        # grammar (README), "and" is the term
        qq = " | ".join('"' + w + '"' for w in ws)
        return (f"SELECT id FROM docs WHERE {col} @@@ to_ftsquery('{cfg}', {lit(qq)}) "
                f"ORDER BY {col} <=> to_ftsquery('{cfg}', {lit(qq)}) LIMIT 100")
    if system == "pgsearch":
        qq = " ".join(ws)
        return (f"SELECT id FROM docs WHERE id @@@ paradedb.boolean(should => ARRAY["
                f"paradedb.match('title', {lit(qq)}), paradedb.match('body', {lit(qq)})]) "
                f"ORDER BY paradedb.score(id) DESC LIMIT 100")
    if system == "tsrank":
        qq = " | ".join(ws)
        return (f"SELECT id FROM docs WHERE tsv @@ to_tsquery('english', {lit(qq)}) "
                f"ORDER BY ts_rank(tsv, to_tsquery('english', {lit(qq)})) DESC, id LIMIT 100")
def dcg(r): return sum(x / math.log2(i + 2) for i, x in enumerate(r))
def run(db, system, qfile, rfile):
    rel = collections.defaultdict(dict)
    for l in open(rfile):
        a = l.rstrip("\n").split("\t")
        if len(a) >= 3: rel[a[0]][a[1]] = float(a[2])
    nd, rc, mr, errs, n = [], [], [], 0, 0
    for l in open(qfile):
        qid, text = l.rstrip("\n").split("\t", 1)
        if qid not in rel: continue
        s = sql_for(system, text)
        out = q(db, s) if s else ""
        if s and not out and "ERROR" in subprocess.run(P+["-d",db,"-c",s],capture_output=True,text=True).stderr: errs += 1
        ranked = [x for x in out.split("\n") if x]
        g = [rel[qid].get(d, 0.0) for d in ranked]
        ideal = sorted(rel[qid].values(), reverse=True)
        nd.append(dcg(g[:10]) / (dcg(ideal[:10]) or 1.0))
        nrel = sum(1 for v in rel[qid].values() if v > 0)
        rc.append(sum(1 for x in g[:100] if x > 0) / nrel if nrel else 0.0)
        mr.append(next((1.0 / (i + 1) for i, x in enumerate(g[:10]) if x > 0), 0.0))
        n += 1
    return {"db": db, "system": system, "queries": n, "errors": errs,
            "ndcg@10": round(sum(nd) / n, 4), "recall@100": round(sum(rc) / n, 4), "mrr@10": round(sum(mr) / n, 4)}
if __name__ == "__main__":
    db = sys.argv[1]
    for system in sys.argv[2:]:
        print(json.dumps(run(db, system, f"/nvme/m2/{db}/queries.tsv", f"/nvme/m2/{db}/qrels.tsv")), flush=True)
