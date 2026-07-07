# pg_fts vs VectorChord-bm25 vs Timescale pg_textsearch — 2.19M Wikipedia

Head-to-head against the two other PostgreSQL BM25 extensions (the ones that,
like pg_fts, maintain corpus statistics and rank from the index).  GIN/tsvector
and RUM are excluded (they have no BM25 and are known to be far slower on ranked
retrieval).

## Environment
- EC2 r7i.4xlarge (16 vCPU Sapphire Rapids, 123 GB), Fedora 43.
- PostgreSQL **17.10** built from source (`--without-icu`, -O2).
- `shared_buffers=32GB`, `work_mem=256MB`, `jit=off`, autovacuum off during runs.
- Corpus: `wikimedia/wikipedia` 20231101.en, first 2,188,038 articles, `body`.
- Engines:
  - **pg_fts 1.20** (this repo) — `bm25` AM, functional index on
    `to_ftsdoc('english', body)`, compacted with `fts_vacuum`.
  - **VectorChord-bm25** (HEAD) + pg_tokenizer — `tsvector` column
    `to_tsvector('english', body)`, `USING bm25 (emb bm25_ops)`, `bm25.limit`.
  - **Timescale pg_textsearch 1.4.0-dev** — `USING bm25(body) WITH
    (text_config='english')`, `ORDER BY body <@> 'q' LIMIT k`.
- Latency: median of 9, warm cache, one engine at a time.

## Index size and build
| engine        | index size | build (CREATE INDEX) | notes |
|---------------|-----------:|---------------------:|-------|
| VectorChord   | 1367 MB    | ~2.3 min             | tsvector-based, no positions |
| pg_textsearch | 1831 MB    | ~4.5 min             | text column, no positions |
| pg_fts        | 7541 MB    | ~26 min + ~41 min `fts_vacuum` | stores term **positions** (phrase/NEAR) + doclen; larger by design |

## Ranked top-10 (ms, lower is better)
| query           | pg_fts | pg_textsearch | VectorChord |
|-----------------|-------:|--------------:|------------:|
| rare (slovakia) | 15.8   | 3.3           | **1.6**     |
| mid (hungary)   | 13.4   | 3.5           | **1.7**     |
| common (year)   | 39.9   | 13.0          | **1.7**     |

## Ranked top-100 (ms)
| query         | pg_fts | pg_textsearch | VectorChord |
|---------------|-------:|--------------:|------------:|
| common (year) | 74.1   | 17.0          | **1.9**     |

## Ranked AND top-10 (ms)
| query      | pg_fts | pg_textsearch | VectorChord |
|------------|-------:|--------------:|------------:|
| rare&mid   | 24.4   | 4.0           | **1.9**     |
| common&mid | 17.6   | 8.5           | **1.7**     |

## Counts (ms) — pg_fts-only capability
Neither VectorChord nor pg_textsearch exposes a match/count predicate; both are
ranking-only (`<&>` / `<@>`).  Only pg_fts can answer `count(*) ... WHERE @@@`
from the index (`fts_count` / the transparent COUNT-pushdown CustomScan):

| query        | pg_fts fts_count | pg_fts count(*) pushdown |
|--------------|-----------------:|-------------------------:|
| rare         | 40.8             | 44.5                     |
| common (736k)| 458              | 547                      |

## Honest reading

**pg_fts is not the best across dimensions.** On ranked retrieval it is the
slowest of the three, by a wide margin:

- **VectorChord wins ranked latency decisively** — ~1.6-1.9 ms flat regardless
  of term frequency or top-k, ~8-40x faster than pg_fts.  Its compact columnar
  codec + block-WeakAND with a hard `bm25.limit` early-terminate is a different,
  deeper investment than pg_fts's block-max WAND over positional postings.
- **pg_textsearch is 2-5x faster than pg_fts** on every ranked query, with a
  4x smaller index and a 6x faster build.
- **pg_fts is largest and slowest to build**, because it stores term positions
  (for phrase/NEAR queries) and per-document length that the other two do not,
  and its `fts_vacuum` compaction is a slow single-threaded rewrite (~20 min per
  pass at 2M).

Where pg_fts is *unique*, not fastest:
- **Counts**: only pg_fts answers `count(*) WHERE match` from the index at all;
  the others have no match predicate.  But at 736k hits it is ~460 ms (collect
  + MVCC visibility over every match), not fast in absolute terms.
- **Query language**: phrase, NEAR, prefix, fuzzy, regex, and boolean over the
  same operator — broader than the plain bag-of-words ranking the other two
  expose.  This is what the extra index size buys.

## Takeaway
For pure BM25 ranked retrieval at this scale, VectorChord is the clear winner
and pg_textsearch is a strong, compact second; pg_fts trails on latency, size,
and build time.  pg_fts's distinguishing value is its richer query language
(positional/phrase/fuzzy/regex) and an index-native COUNT — not raw ranked
speed.  Closing the ranked gap is a posting-codec problem (compact columnar +
rank/select skip, and a hard top-k early-termination), documented in
bench/NOTE_FORMAT_V3_PROFILE.md and ROADMAP.md; the code-level levers tried so
far (impact-ordering, parallel scan) did not close it.

Measured: EC2 r7i.4xlarge, PostgreSQL 17.10, 2,188,038 Wikipedia articles,
pg_fts 1.20 / VectorChord-bm25 HEAD / pg_textsearch 1.4.0-dev.
