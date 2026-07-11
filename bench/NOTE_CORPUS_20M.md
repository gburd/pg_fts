# Corpus research for a ~20M-doc diverse pg_fts benchmark

Read-only research. Goal: 10x the prior 2.19M-Wikipedia benchmark to ~20M
documents, mixing DIVERSE sources (Wikipedia prose + JSON logs + reviews +
abstracts + code/Q&A) into ONE `docs(id, title, body)` table indexed by
`to_ftsdoc('english', body)`, so the analyzer/term-dictionary/trigram index get
stressed with heterogeneous content — and so results are comparable to what
competing FTS/BM25 systems publish.

Conventions used below:
- **VERIFY** = a specific number I'm not 100% sure of from memory; check before
  citing in the final benchmark writeup. Dataset *existence* and HF ids are
  high-confidence unless flagged.
- Sizes are uncompressed text unless noted "parquet"/"gz".

---

## 1. What competitors and adjacent systems benchmark with

### 1.1 ParadeDB `pg_search` (Tantivy under Postgres)
- **Logs / Elasticsearch comparison benchmark.** ParadeDB's headline blog
  benchmark ("pg_search vs Elasticsearch") uses a **generated log dataset** —
  synthetic structured log events (numeric + text + timestamp fields), commonly
  cited around **~1 billion rows** for the big run and smaller (**~100M / ~40M**)
  for mid tiers. It is JSON-log-shaped (mixed structured fields), not natural
  prose. Their generator lives in the `paradedb/paradedb` repo under the
  benchmark/`cargo-paradedb` tooling (a `pgrx`/`cargo paradedb bench` corpus
  generator that emits `mock` log rows). **VERIFY exact row counts + whether
  current blog uses 1B or 100M**; ParadeDB has re-run this several times.
- **Wikipedia.** ParadeDB has also published Wikipedia-article benchmarks
  (single-node, BM25 search/rank latency) — the same `wikimedia/wikipedia`
  English dump family we already use. Scale in their posts is typically the
  **full English article set (~6–7M)** or a few-million subset. **VERIFY.**
- Takeaway for us: ParadeDB's *credible* comparison is the **logs** dataset
  vs Elasticsearch. If we want to be directly comparable to their strongest
  published claim, we need a large **log** component — which aligns with the
  user's "a lot of JSON logs" request.

### 1.2 VectorChord-bm25 (`vchord_bm25`, TensorChord/PostgresML-adjacent)
- Their published BM25 benchmark is an **IR-relevance + latency** benchmark on
  **BEIR / MS MARCO**-style datasets, emphasizing that their BM25 scoring
  matches Lucene/Elasticsearch and beats `ParadeDB`/`tsvector` on latency.
- Concretely they've shown **MS MARCO passage** (~8.8M passages) and several
  **BEIR** subsets (NFCorpus, Quora, FiQA, SciFact, TREC-COVID, etc.) reporting
  **NDCG@10** parity with Elasticsearch plus query latency. **VERIFY which BEIR
  subsets + whether they published full MS MARCO or a subset.**
- Takeaway: for a *relevance* (not just latency) story, MS MARCO + a couple of
  BEIR subsets is the lingua franca. We already reference MS MARCO in
  `bench/README`.

### 1.3 Elasticsearch / OpenSearch — the `esrally` (Rally) tracks
These are the de-facto standard, and several are text/log heavy. Repo:
`github.com/elastic/rally-tracks`. Sizes are the well-known Rally figures
(**VERIFY** against the track's `track.json` `uncompressed-bytes` for exact
numbers, but these are the widely-cited values):

| Track | Content | Docs | Approx size | Relevance to us |
|-------|---------|-----:|------------:|-----------------|
| `http_logs` | **Web server access logs (Apache/ELB-style), JSON** | **~247M** events | ~32 GB uncompressed | **Primary log analog.** This is the canonical "JSON logs" ES benchmark. |
| `nyc_taxis` | Taxi rides, numeric-heavy JSON | ~165M | ~75 GB | Structured, little text — less useful for FTS. |
| `geonames` | Place names, short docs | ~11M | ~3 GB | Short-text, high name cardinality. |
| `geopoint` | Geo points | ~60M | — | Not text. |
| `pmc` | **PubMed Central full-text medical articles** | **~574k** | ~5.5 GB | **Long-form prose**, technical vocab. Small doc count but big docs. |
| `nested` / `so` | **StackOverflow posts (questions+answers)**, JSON w/ nested | **~30M** posts | ~10–30 GB | **Code + Q&A text**, great diversity (code tokens, tags). `so` track. |
| `noaa` | Weather, numeric | ~33M | — | Not text. |
| `percolator` | Queries | small | — | N/A. |

- **Text/log-heavy = `http_logs` (logs), `so` (StackOverflow code+prose),
  `pmc` (medical prose), `geonames` (short names).** These four map cleanly to
  the diversity the user wants.
- Being able to say "we ran the equivalent of Rally `http_logs` + `so` + `pmc`"
  makes our benchmark legible to any ES/OpenSearch reader.

### 1.4 Lucene nightly benchmarks (`luceneutil`)
- Repo `mikemccand/luceneutil`. Uses an **English Wikipedia export**. The two
  standard sizes are the **~1M-doc** line-doc file and the **full
  ~6.6M-article** `enwiki` export (the nightly charts at
  `home.apache.org/~mikemccand/lucenebench/` run on the multi-GB enwiki dump).
  Docs are one-article-per-line. **VERIFY current exact article count** (grows
  with each dump; ~6.6M is the recent English total).
- Takeaway: Lucene's baseline is *Wikipedia*, same family as ours — good, our
  Wikipedia component is already apples-to-apples with Lucene.

### 1.5 Tantivy's own benchmarks
- Tantivy's `search-index-benchmark-game` (`tantivy-search/search-benchmark-game`)
  compares Tantivy vs Lucene vs PISA vs Bleve on an **English Wikipedia** corpus
  (again the ~6–7M article set), reporting query throughput for AND/OR/phrase/
  top-k. Same Wikipedia family. **VERIFY exact corpus snapshot.**

### 1.6 BEIR / MS MARCO (IR relevance, for NDCG/recall — not latency)
- **MS MARCO passage ranking**: **~8.84M passages**, ~1GB text; qrels + queries
  available. HF: **`BeIR/msmarco`** (and `microsoft/ms_marco`,
  `mteb/msmarco`). This is the single most-cited BM25 relevance corpus.
- **BEIR** = 18-dataset zero-shot IR suite (NFCorpus, Quora, FiQA-2018,
  SciFact, SCIDOCS, ArguAna, TREC-COVID, DBPedia-entity, HotpotQA, NQ, FEVER,
  Climate-FEVER, CQADupStack, Touché-2020, Signal-1M, TREC-NEWS, Robust04,
  BioASQ). HF org: **`BeIR/*`** (e.g. `BeIR/nfcorpus`, `BeIR/scifact`,
  `BeIR/trec-covid`, `BeIR/fever`). Sizes range from **~3.6k docs (NFCorpus)**
  to **~5.4M docs (MS MARCO/FEVER-scale)**. **VERIFY per-subset counts.**
- Use these for the *quality* half of a credible writeup (NDCG@10 vs Lucene/ES),
  separate from the 20M latency/scale run. They are mostly too small to
  contribute meaningfully to a 20M doc count except MS MARCO (8.8M).

### 1.7 ClickBench and JSON-log corpora
- **ClickBench** (`github.com/ClickHouse/ClickBench`) is analytics-oriented
  (web-hits, ~100M rows) — mostly numeric/categorical, **not FTS**. Not a good
  fit except as a "structured events" flavor. Skip for text.
- The recognized *real* log corpus in research is **Loghub**
  (`github.com/logpai/loghub`): 16+ real-system log datasets (HDFS, Hadoop,
  Spark, Zookeeper, BGL, HPC, Thunderbird, Windows, Linux, Mac, Android,
  HealthApp, Apache, OpenSSH, OpenStack, Proxifier). Total **~77 GB across
  ~440M lines** in the full "loghub-2.0"/large collection; the classic small
  set is a few hundred MB. **VERIFY the 440M/77GB figure** — the widely-quoted
  number for the full release is "~77GB, largest single (Thunderbird) ~30GB".
- For *bulk generated* logs, ES `http_logs` (§1.3) is the easiest single large
  homogeneous JSON-log source.

---

## 2. Downloadable diverse sources to build ~20M docs (ranked by fit)

Ranked by (diversity value × ease of bulk download). All are `body text` after
extraction. "prose" vs "structured/JSON" flagged.

| # | Source | HF id / URL | Approx docs available | Approx size | Type | License / access | Notes |
|---|--------|-------------|----------------------:|------------:|------|------------------|-------|
| 1 | **English Wikipedia (full)** | HF `wikimedia/wikipedia`, config `20231101.en` | **~6.41M articles** (this is the real total; we only used first 2.19M before) | ~20 GB parquet, ~19 GB text `body` | prose | CC BY-SA / GFDL, no auth | Already wired in `bench/get_wikipedia.py`. **VERIFY exact article count of 20231101.en — commonly cited ~6.41M.** |
| 2 | **HTTP/web access logs** | ES Rally `http_logs` track — data at `github.com/elastic/rally-tracks/tree/master/http_logs` (S3-hosted `documents.json` bundles) | **~247M** log lines (JSON) | ~32 GB uncompressed | structured/JSON | Apache-2.0 track; data public | **Best "a lot of JSON logs" source.** Each line already JSON `{"@timestamp":..,"clientip":..,"request":"GET /..","status":200,"size":..}`. Index raw line as `body`. Take a ~8M subset. |
| 2b | **Loghub real system logs** | `github.com/logpai/loghub` (+ Zenodo mirrors, HF `logpai/loghub` mirrors exist for some) | **~10s–440M lines** depending on release | few hundred MB (classic) to ~77 GB (loghub-2.0) | semi-structured plain-text logs | research/academic, mostly open; check per-dataset | More *realistic heterogeneous* logs (HDFS/Spark/BGL/OpenStack) than synthetic http_logs — great vocab diversity (hex ids, hostnames, stack frames). Harder to bulk-fetch uniformly. Use as a *flavor* mix if time allows. |
| 3 | **StackOverflow posts** | HF `mikex86/stackoverflow-posts` (or the ES Rally `so`/`nested` track data; also `HuggingFaceH4`/`bigcode` mirrors) | **~60M** posts (questions+answers) available; Rally `so` uses ~30M | ~40–100 GB | prose+code JSON | CC BY-SA | **Code tokens + Q&A prose = huge vocab diversity.** Body = post text (contains code blocks). **VERIFY exact repo id + count.** |
| 4 | **Amazon product reviews** | HF `McAuley-Lab/Amazon-Reviews-2023` (successor to `amazon_us_reviews`, which was deprecated/gated on HF) | **~571M** reviews total (2023); pick a category subset | 100s of GB total; per-category GB-scale | prose (short) | research use; some gating — **VERIFY access terms** | Short informal prose, product/brand vocab. `amazon_us_reviews` old HF dataset was removed — use McAuley-Lab 2023. |
| 5 | **PubMed abstracts** | HF `pubmed` (NLM baseline) or `ncbi/pubmed`; also Rally `pmc` for full-text | **~24–36M** abstracts (PubMed baseline) | ~20–40 GB text | prose (technical) | NLM public domain (US gov) | **Excellent technical-vocab diversity** (gene names, chemistry). Abstracts are short-to-medium prose. **VERIFY HF id — `pubmed` config naming has changed; may need `ncbi_pubmed` or the annual baseline XML.** |
| 6 | **arXiv abstracts** | HF `arxiv-community/arxiv_dataset` or Kaggle `Cornell-University/arxiv` (metadata JSON) | **~2.4M** papers | ~4 GB (metadata json) / abstracts ~2 GB text | prose (technical) | CC0 metadata | LaTeX-flavored math tokens, dense technical vocab. Easy: single ~4GB JSON. |
| 7 | **CC-News** | HF `cc_news` (or `vblagoje/cc_news`) | **~708k** news articles | ~2 GB | prose | Common Crawl terms | Journalistic prose; modest count. |
| 8 | **C4 (Common Crawl cleaned)** | HF `allenai/c4`, config `en` | **~365M** web docs | ~750 GB (full en); `en.noblocklist`/subsets available | prose (web) | ODC-BY | Effectively unlimited filler if we need to top up to 20M cheaply; very heterogeneous web text. Stream a slice. |
| 9 | **Reddit comments** | HF `bigcode`/`webis` mirrors; Pushshift dumps (`files.pushshift.io` — **access now restricted**, VERIFY) | billions available | huge | prose (informal) | contested/gated | Informal + emoji + slang vocab. Access is the problem post-2023; prefer an HF mirror. **VERIFY availability.** |
| 10 | **HackerNews** | HF `OpenPipe/hacker-news` or BigQuery `bigquery-public-data.hacker_news` | **~40M** items (comments+stories) | ~10 GB | prose (informal/tech) | public | Tech-forum vocab, code snippets, URLs. |

**Cheapest paths to bulk volume:** Wikipedia (already wired), http_logs
(single S3 bundle), arXiv (one JSON), C4 (stream to top up). The gated/awkward
ones (Amazon 2023, Reddit/Pushshift) are optional flavor, not load-bearing.

---

## 3. Concrete ~20M mixed-corpus recipe (one table, one index)

Target mix (~20.0M docs) chosen for **maximum vocabulary + doc-length spread**
while staying easy to fetch:

| Component | Docs | Type | Why included | Source |
|-----------|-----:|------|--------------|--------|
| English Wikipedia (all) | **6.4M** | long prose | baseline, comparable to Lucene/Tantivy | HF `wikimedia/wikipedia 20231101.en` |
| HTTP JSON logs (subset) | **8.0M** | structured JSON | "a lot of JSON logs", ParadeDB/ES analog, high-cardinality tokens | ES Rally `http_logs` (take 8M of ~247M lines) |
| StackOverflow posts (subset) | **2.0M** | prose+code | code tokens, tags, Q&A | HF `mikex86/stackoverflow-posts` |
| PubMed/arXiv abstracts | **2.6M** | technical prose | dense technical vocab, medium length | HF `pubmed` (2M) + `arxiv_dataset` (0.6M) |
| Amazon reviews (subset) | **1.0M** | short informal prose | short-doc tail for BM25 length-norm | HF `McAuley-Lab/Amazon-Reviews-2023` (one category) |
| **Total** | **~20.0M** | | | |

Adjust freely: if StackOverflow/Amazon access is friction, top up with **C4**
(`allenai/c4` en, streamed) — it's the zero-friction filler.

### 3.1 Output format (reuse the existing harness verbatim)
`bench/load.sh` already does `\copy docs (id, title, body) FROM '$CORPUS'
WITH (FORMAT csv, DELIMITER E'\t')` and builds `USING bm25
(to_ftsdoc('english', body))`. So every source must emit **one TSV line**:

    <global_id>\t<title>\t<body>

exactly like `get_wikipedia.py`. For non-Wikipedia sources:
- **JSON logs**: `title` = source tag (e.g. `httplog`); `body` = the **raw JSON
  line as text**. `to_ftsdoc('english', body)` will tokenize keys+values
  (`clientip`, `GET`, `status`, the IP octets, the URL path segments,
  timestamps) as terms. That's exactly the stress we want, and it's realistic
  for "index the log line, search it later / anomaly detection."
- **StackOverflow / reviews / abstracts**: `title` = post/product/paper title;
  `body` = the text (strip HTML for SO; keep code blocks — code tokens are
  desirable diversity).
- Keep the per-source `id` unique by **offsetting** each source into its own
  numeric range (Wikipedia keeps its ids; logs start at e.g. 1e9; SO at 2e9;
  etc.) so `id` stays a unique `bigint`.

### 3.2 Build outline (mirror `get_wikipedia.py`, append to one TSV)
One small Python script per source, all appending to `/data/mixed.tsv`, reusing
the exact escaping the current script uses (`.replace("\t"," ").replace("\n"," ")`):

    # pattern already in get_wikipedia.py — for each source:
    #   download shard -> iterate rows -> write f"{gid}\t{title}\t{body}\n"
    #   sanitize tabs/newlines; delete shard; print progress to stderr
    # sources: wiki (existing), http_logs (json.loads then dump line as body),
    #          stackoverflow, pubmed+arxiv, amazon-reviews

Then the **unchanged** `load.sh /data/mixed.tsv`.

### 3.3 Size, time, and gotchas
- **On-disk heap**: Wikipedia `body` alone is ~19 GB at 6.4M. Logs ~1–1.5 GB
  for 8M short JSON lines. Abstracts ~4 GB. SO ~4–8 GB. Reviews ~1 GB. Rough
  **heap ~30–40 GB**; the bm25 index historically ran ~1.07x heap on prose but
  **log/JSON tokens inflate the term dictionary** (see §4), so budget the index
  at **~1.2–1.6x heap → provision ≥120–150 GB disk** to be safe. **VERIFY on a
  small pilot.**
- **Download/prep time**: Wikipedia ~20 GB parquet (existing script, tens of
  minutes on EC2 with good bandwidth). http_logs bundle ~a few GB gz. Total
  fetch **~1–2 h**; TSV assembly single-threaded like the current script
  (I/O + string sanitize) another **~1 h**. `CREATE INDEX` at 20M is the long
  pole — the 2M Wikipedia build was **~21m single-backend**; 20M mixed with a
  fatter dictionary could be **hours** single-threaded (analysis is
  single-threaded per prior notes). Consider parallel `ambuild` if available;
  prior notes flag a **1 GB palloc overflow bug at 2.19M on some HEADs** —
  reconfirm the build is fixed before committing to 20M.
- **Invalid UTF-8** (the prior blocker): the 0.2.2 run needed `iconv -c` to
  clean invalid bytes in `body` (`RESULTS_V022.md`: 6.59 GB, 0 rows lost).
  **Do the same on the assembled TSV**: `iconv -c -f UTF-8 -t UTF-8
  mixed.tsv > mixed.clean.tsv`. Logs and scraped text are worse offenders than
  Wikipedia — sanitize before `\copy` or the load aborts on the first bad byte.
- **Embedded tabs/newlines**: keep the `.replace("\t"," ").replace("\n"," ")`
  on every field for every source (JSON log lines can contain newlines in
  message fields; strip them or the TSV row count breaks).
- **HF auth / rate limits**: `wikimedia/wikipedia`, `allenai/c4`,
  `cc_news`, `arxiv_dataset` are ungated. **Amazon-Reviews-2023 and some PubMed
  mirrors may require `huggingface-cli login`** — VERIFY and set `HF_TOKEN`.
  Pushshift/Reddit direct is restricted; use an HF mirror or drop it.
- **Dedup**: cross-source dedup is unnecessary for a stress test (sources don't
  overlap). Within http_logs subset, don't dedup — duplicate log lines are
  realistic and stress term-frequency skew.

---

## 4. Why diversity matters for THIS index specifically

The whole point of mixing is that heterogeneous content exercises code paths a
single-source (Wikipedia-only) run never touches:

1. **Term dictionary size explosion.** JSON logs contribute
   **high-cardinality, near-unique tokens**: IP addresses, UUIDs, epoch/ISO
   timestamps, URL path segments, request ids, hex hashes (Loghub especially).
   Each is essentially a distinct term with df≈1. This **balloons the distinct
   term count (T)** far beyond prose. Prior notes (`NOTE_SIZE_AND_SPEED.md`,
   `NOTE_SIZE_SPEED_REPLAN.md`) already flag doclen being written per
   `(doc × distinct-term)` pair and "high T → dedup should help" — a log-heavy
   corpus is precisely the worst case that makes those costs measurable.
   **Watch: term-dictionary bytes, dict-page lookups per query, build memory
   (the 1 GB palloc overflow lived in this path).**

2. **Trigram / fuzzy / regex index stress.** The optional trigram index
   (`pg_fts_trgm.c`) sizes with distinct terms and their trigram fan-out.
   UUIDs/hex/URLs generate enormous numbers of *rare* trigrams — a realistic
   worst case for fuzzy (`<%>`) and regex scans. Q6 fuzzy was already the
   weakest column vs pg_search (227 ms); a high-cardinality corpus is the honest
   place to measure it. **Watch: trigram index size and fuzzy-count latency.**

3. **BM25 length-normalization & doclen distribution.** Mixing **long
   Wikipedia articles (~3000 chars), medium abstracts, short reviews, and tiny
   one-line logs** produces a **wide, multi-modal doclen distribution**. BM25's
   `b`-parameter length normalization and `avgdl` are only meaningfully
   exercised when doc lengths vary by orders of magnitude — a Wikipedia-only run
   has a narrow unimodal distribution and hides length-norm bugs. **Watch:
   `avgdl` sanity, score stability across doc-length buckets, WAND/MaxScore
   pruning behavior when doclens are extreme (the k-growth cliff in
   `RESULTS_VS_PGSEARCH.md`).**

4. **Corpus statistics / ranking realism.** Distinct df distributions from five
   vocabularies (natural language + code + log tokens + technical terms) make
   idf and top-k ordering closer to a real production index than any single
   source. This is also directly relevant to the **anomaly-detection** angle:
   indexing raw JSON log lines as text and then querying for rare tokens is a
   legitimate "find the needle" workload, and a high-cardinality dictionary is
   exactly what an anomaly-detection index looks like.

**Summary of what to measure that Wikipedia-only can't show:** distinct-term
count and dictionary bytes, build peak RSS (palloc path), trigram index size,
fuzzy latency at high cardinality, and BM25 behavior across a multi-modal
doclen distribution.

---

## Items to VERIFY before publishing numbers
- Exact article count of `wikimedia/wikipedia 20231101.en` (~6.41M).
- ParadeDB logs benchmark current scale (1B vs 100M) and generator invocation.
- ES Rally `http_logs` (~247M) and `so` (~30M) exact `uncompressed-bytes`.
- MS MARCO passage count (~8.84M) and which BEIR subsets VectorChord published.
- Loghub full-collection size (~77 GB / line count).
- HF ids and access gating for: `mikex86/stackoverflow-posts`,
  `McAuley-Lab/Amazon-Reviews-2023`, the current PubMed HF config, and whether
  Reddit/Pushshift has any ungated HF mirror.
- Lucene `luceneutil` current enwiki article count (~6.6M).
