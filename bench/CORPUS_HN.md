# The HackerNews corpus (pg_fts tests and benchmarks)

Added 2026-11-23 after the 1.18.1 field report: a wide boolean filter over a
150M-document HackerNews index raised `invalid memory alloc request size` in
549 of 3,762 queries, and 8 clients exhausted a 64 GiB container.  Every pg_fts
test and benchmark until then used at most the 2.19M-article Wikipedia corpus,
about 70x too small for the collect path's buffers to cross 1 GB, and none
measured memory.  HackerNews is the second standing corpus: short, informal,
technical text with code, URLs and many stopword-heavy comments.  It is the
field corpus, at the field's scale.

## Source

| | |
|---|---|
| dataset | Hugging Face `open-index/hacker-news` ("Hacker News - Complete Archive"), every HN API item since 2006 |
| license | ODC-BY 1.0 (attribution: the open-index/hacker-news dataset, data from the Hacker News API) |
| pinned revision | `c54ced5973b95d80cd934b8921f44ec8d87c3cd1`; the dataset updates every 5 minutes, so the commit pin is what makes a build reproducible |
| files | 239 monthly Parquet files, `data/2006/2006-10.parquet` .. `data/2026/2026-08.parquet`, 12.4 GB |
| items | about 49.3M (43.1M comments, 6.3M stories, the rest jobs and polls) |

## Construction (`bench/hn_corpus.py`)

- One document is one item that is neither `deleted` nor `dead` and has a
  title or text.  `content = title + ' ' + text`, with HTML tags removed and
  entities decoded (comment and Ask HN bodies are HTML).  Tabs, newlines and
  backslashes become spaces, so the file loads with `COPY ... (FORMAT text)`
  into `(id bigint, content text)`.
- Items are emitted in id order (the order HN created them).  The id is the
  HN item id.
- A tier larger than the archive is built by **replication**: copy k of item
  i gets id `k * 100000000 + i` and the same content.  This keeps the term
  distribution and document lengths, and multiplies every df and every match
  set by the replication factor.  That is right for scale (index size, build
  time and memory, wide-filter match sets) and wrong for relevance: copies tie
  in BM25.  The lock file records the factor.
- Every build writes `hn_corpus.lock.json`: revision, file list with sizes,
  rows, distinct items, replication factor, and the md5 of the TSV.  The same
  revision and tier give the same bytes (checked: two smoke builds, md5
  `3732302b...`).

| tier | rows | use |
|---|---|---|
| `smoke` | 144,393 (one month, 2015-01) | harness checks; minutes on a laptop |
| `1m` | 1,000,000 | quick EC2 regression |
| `10m` | 10,000,000 | scale regression for scan/collect/alloc changes |
| `full` | every usable item (about 45M, measured when first built) | the archive, unreplicated |
| `150m` | 150,000,000 (about 3.3 copies) | the field scale: memory and match-set tests |

Smoke-tier shape: 144,393 documents from 155,164 items (4,964 deleted, 6,300
dead, 2 empty), 56.8 words per document on average, 186 MB of heap, a 20 MB
fts index.

## Queries (`bench/hn_queries.py`)

Zishuo's 3,762 queries are not available yet (he offered his scripts).  The
trace reproduces their shape from real HN text.  It draws words from the
newest 20,000 items of the tier with a fixed seed, so it is deterministic.
Those items are in the corpus too, so every query matches at least one
document, which is fine for a scale trace and not a relevance set:

- `or_2` .. `or_8`: k adjacent words OR'ed, stopwords included (the field
  example was `'firebase' | 'analytics' | 'i' | 'don' <-> 't' | 'think' | 'that'`);
- `and_2`: two adjacent words AND'ed;
- `phrase_2`: two adjacent words as a phrase.

Every query is emitted twice: as a bare filter (`count(*) ... WHERE d @@@ q`,
the eager collect path) and as a ranked top-10 (`ORDER BY d <=> q LIMIT 10`,
the bounded WAND path).  Only the first one failed in the field.

## The scale test (`bench/hn_scale.sh`)

Phases:

1. `load`: COPY, then a stored `d ftsdoc` column (`to_ftsdoc('english',
   content)`), then `VACUUM (FREEZE, ANALYZE)`.
2. `build`: `CREATE INDEX ... USING fts (d)`, with time, size and the
   building backend's peak RSS.
3. `check`: the counts of three probe terms through the index against a
   forced heap scan.  A mismatch, or a zero (AGENTS rule 9), fails the run.
4. `trace`: every statement on its own backend, recording ok/error, ms, and
   the backend's peak RSS (`VmHWM`).  Errors go to `trace_errors.txt`, with
   a summary per band and form.
5. `conc`: the filter statements from `CLIENTS` sessions at once, counting
   failures.  To reproduce the field's container, start the server under a
   memory cap (`systemd-run --user --scope -p MemoryMax=64G pg_ctl ...`).

```sh
python3 bench/hn_corpus.py 10m /scratch/pg_fts/hn10m
python3 bench/hn_queries.py /scratch/pg_fts/hn10m/hn_10m.tsv 2000 /scratch/pg_fts/hn10m/trace.tsv
PGHOST=... PGPORT=... bash bench/hn_scale.sh "$(pg_config --bindir)" \
    /scratch/pg_fts/hn10m/hn_10m.tsv /scratch/pg_fts/hn10m/trace.tsv /scratch/pg_fts/hn10m/run
```

Checked on the smoke tier (PG 17.11, 1.18.1, 2026-11-23): load, build (1.8 s,
187 MiB peak), check (`rust` 609 = 609, `postgres` 138 = 138, `people` 18,585 = 18,585),
200 queries x 2 forms with 0 errors, and 8 x 200 concurrent filters with 0
failures.  A negative control (a syntax error and an oversized allocation
injected into the trace) was counted as 2 errors with their messages.

## Open

- The `10m`, `full` and `150m` runs on EC2 (ROADMAP M5).  150m needs the host
  the 59.7M-post Stack Overflow build needed or more (about 130-140 GB at
  `maintenance_work_mem = 24GB`, ROADMAP M4): an r-class instance with 512 GB
  and local NVMe.
- Zishuo's trace, when he sends it, run unchanged alongside this one.
- A relevance set for HN does not exist; this corpus is for scale, memory and
  latency, not NDCG.
