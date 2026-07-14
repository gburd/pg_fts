# PostgreSQL BM25 solutions — competitive landscape and "de facto" outlook

Written 2026-07-14. Facts: adoption signals from GitHub (stars / activity /
license / backing, retrieved this date); performance from `bench/RESULTS_VS_CURRENT.md`
(pg_fts 0.3.5 vs VectorChord-bm25 HEAD vs pg_textsearch 1.4.0-dev, 2.19M
Wikipedia, matched Snowball analyzer, r7i.4xlarge). This is an honest read,
including where pg_fts loses.

## The solutions

| Solution | Impl / engine | License | Backing | ⭐ | Activity | Status |
|---|---|---|---|---|---|---|
| **ParadeDB pg_search** | Rust, embeds **Tantivy** (Lucene-like) | AGPL-3.0 | ParadeDB (VC-backed co.) | ~9.0k | daily | Production, marketed |
| **Timescale pg_textsearch** | C, native BM25 index AM | **PostgreSQL** | Timescale (co.) | ~3.9k | daily | Active, younger |
| **VectorChord-bm25** | Rust (pgrx), BM25 over tsvector | non-standard | TensorChord (co.) | ~0.4k (fork) / VectorChord ~1.7k | active | Active, niche |
| **ZomboDB** | PL/pgSQL + external **Elasticsearch** | non-standard | (originally ZomboDB/TCDI) | ~4.7k | **archived** | **Dead** (archived 2025) |
| **pg_fts** (this) | C, native BM25 index AM | **PostgreSQL** | single maintainer | (Codeberg) | active | 0.3.5, on PGXN |

(pg_tokenizer, `rum`, and plain `tsvector`+GIN+`ts_rank` are adjacent but not
true BM25 index AMs — `rum` stores positions/rank data but is not BM25;
tsvector/GIN is the built-in baseline everyone beats on ranked retrieval.)

## Where pg_fts stands, measured (0.3.5)

- **Index size**: ~2.9× VectorChord, ~2.2× pg_textsearch (pos=off). Larger, but
  the gap roughly halved from the 1.20 era once positions became opt-in.
- **Ranked top-10 latency**: ~2–6× VectorChord, ~3–5× pg_textsearch. Still the
  weak axis (decode-bound; no impact-ordered codec yet).
- **Capability (pg_fts-only among these)**: index-native `count(*)` / `fts_count`;
  positional phrase / NEAR; boolean AND/NOT; prefix / fuzzy / regex — all over
  one `@@@` / `<=>` surface. VectorChord and pg_textsearch are bag-of-words
  ranking-only (no match/count predicate, no phrase). ParadeDB has the richest
  query surface of the competitors (Tantivy), plus faceting/aggregations.
- **Correctness / PG-nativeness**: 100% GenericXLog WAL, MVCC, CIC/REINDEX,
  crash-recovery + replication tested; `trusted` extension; PostgreSQL license.

## Likelihood of becoming the de facto solution — ranked

Criteria weighed: adoption + backing, license/governance, performance,
capability breadth, PostgreSQL-nativeness/maintainability, momentum.

### 1. ParadeDB pg_search — **most likely** (today's front-runner)
- **For**: by far the largest adoption (~9k⭐) and mindshare; a funded company
  whose whole product is this; Tantivy is a mature Lucene-class engine → strong
  ranked speed, faceting, phrase, rich queries; heavy marketing + docs.
- **Against**: **AGPL-3.0** is a real adoption blocker for many companies and
  effectively for core/contrib inclusion; Tantivy lives somewhat outside
  PostgreSQL's WAL/MVCC/buffer model (a bolt-on index engine), which complicates
  the "just works like a PG index" story; heavier dependency (Rust + Tantivy).
- **Verdict**: the market leader by adoption and the one to beat, but its license
  and non-native architecture cap its ceiling as *the* PostgreSQL-native default.

### 2. Timescale pg_textsearch — **strongest "native default" candidate**
- **For**: **C + PostgreSQL license** (the two things that matter for becoming a
  *default*/contrib-track solution); a credible company (Timescale) behind it;
  fastest ranked latency in our test and a compact index; growing fast (~3.9k⭐,
  daily activity). Licensing + language make it the most "upstreamable-shaped".
- **Against**: youngest of the serious three; ranking-only (no phrase/boolean/
  count predicate today); tied to a single vendor's roadmap; feature breadth
  well behind ParadeDB.
- **Verdict**: if "de facto" means *the PostgreSQL-native BM25 people reach for
  by default*, this is the most likely — permissive license + C + vendor backing
  + best measured latency. The capability gap is its main risk.

### 3. pg_fts (this project) — **the correctness/capability play, adoption-limited**
- **For**: the **only** one with index-native `count(*)`, positional phrase,
  boolean, and fuzzy/regex over one operator; the most PostgreSQL-native
  (GenericXLog/MVCC/CIC/trusted, PostgreSQL license); correctness is a genuine
  differentiator (three crash classes found + fixed + fuzz/ASan/property/90%-
  coverage-gated CI). Honest, verifiable positioning.
- **Against**: single maintainer, no company/marketing, low adoption; ~2.9×
  larger index and ~2–6× slower ranked than the leaders — and *ranked latency +
  size are exactly the axes most benchmark-driven adopters optimize for*.
- **Verdict**: unlikely to be *the* default on raw adoption/latency, but the
  strongest on **query-language breadth + count + native correctness** — a real
  niche (log/metadata search, boolean/phrase workloads, count-heavy analytics,
  and users who want a permissive, PG-native, auditable AM). Its path to
  relevance is that niche + closing the size gap (doclen sidecar) and the
  latency gap (impact-ordered codec), not out-adopting ParadeDB.

### 4. VectorChord-bm25 — **niche / bundled with vector search**
- **For**: fast, compact; TensorChord bundles it with vector search
  (VectorChord), so it rides that adoption; active.
- **Against**: smallest standalone BM25 adoption; non-standard license; ranking-
  only; primarily interesting to teams already in the VectorChord/vector stack.
- **Verdict**: persists as part of a hybrid-search stack, not a standalone BM25
  default.

### 5. ZomboDB — **effectively out** (archived)
- Historically significant (Elasticsearch-backed FTS in PG), but the repo is
  **archived** (dead as of 2025) and depends on an external Elasticsearch — the
  opposite of a self-contained PG-native index. Not a going-forward contender.

## Bottom line

- **Most likely de facto, by adoption today**: **ParadeDB pg_search** — but
  AGPL + non-native architecture cap it as *the* PostgreSQL-native default.
- **Most likely to become the native default** (permissive C, vendor-backed,
  fastest, upstreamable-shaped): **Timescale pg_textsearch**, if it grows the
  query-capability set.
- **pg_fts** does not win the adoption or latency race and should not be
  positioned as if it will. Its defensible, honest place is **capability +
  correctness + PostgreSQL-nativeness**: index-native count, the full
  boolean/phrase/NEAR/prefix/fuzzy/regex query language, and an auditable,
  WAL/MVCC-correct, permissively-licensed AM. To move up this list it must close
  the **size** gap (ROADMAP doclen sidecar → ~40% smaller) and the **ranked
  latency** gap (impact-ordered postings + hard top-k), which are the two axes
  benchmark-driven adopters actually compare on.
