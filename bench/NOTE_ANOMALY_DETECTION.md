# Design note: can a BM25 inverted index answer "which entries are anomalous?"

A design exploration (no code) of whether pg_fts's index structure can identify
the top-0.1% most anomalous documents/log-lines (or the inverse — the most
typical), and how quickly. Grounded in what pg_fts actually stores; honest about
what is cheap, what is expensive, and what it cannot do.

## What "anomalous" means for a lexical index, and what pg_fts already has

An inverted index with corpus statistics is, structurally, a store of **lexical
rarity and per-document term distributions** — which is most of what "textual
anomaly" means. pg_fts maintains exactly the raw material:

- **Per-term document frequency `df`** → `idf = log(1 + (N − df + 0.5)/(df + 0.5))`
  (`pg_fts_rank.c:74`). idf **is** a rarity score: a term in 3 of 20M docs has
  huge idf; a term in half the corpus has ~0. This is a per-term surprise value,
  already computed and exposed via `fts_index_df` / `fts_index_stats`.
- **Corpus stats** `N`, `avgdl`, `sum(doclen)` (`fts_index_stats`).
- **Per-document, per-term `tf` and document length `doclen`** in the postings.
- **A trigram index over the vocabulary** (for fuzzy/regex) — i.e. a
  character-n-gram view of every distinct term.

So the honest framing: pg_fts is not an anomaly detector, but it is a
**precomputed lexical-rarity store**, and several useful notions of "anomalous
text" reduce to aggregates over data it already holds.

## Definitions of anomaly and how each maps onto the index

"Anomalous" is not one thing. Four useful definitions, in rough order of how
well the index answers them:

### 1. Rare-vocabulary anomaly — "contains terms almost nothing else has"
A log line with a UUID, a stack-trace symbol, a one-off error string, or a
never-before-seen token. **This is the index's home turf.** Define a per-document
lexical-surprise score, e.g. the max or mean idf over the document's terms:

  `surprise(d) = max_{t in d} idf(t)`  (a doc containing a globally near-unique
  term) or `mean_{t in d} idf(t)` (a doc that is *mostly* rare terms).

The index has idf per term (from df) and the term set per doc (postings). The
top-0.1% by max-idf is essentially "documents containing a hapax/near-hapax
term" — a very natural anomaly signal for logs (new error codes, novel
identifiers). **The inverse** ("least anomalous / most typical") is the low-
surprise tail: documents built entirely from common terms — boilerplate, the
"normal" log lines.

### 2. Statistical-outlier anomaly — "term frequencies unlike the corpus"
A doc where a term appears far more often than its corpus rate would predict
(tf ≫ expected given df/N), or an unusual length. BM25 itself is a
tf-saturated, length-normalized surprise model; the per-doc tf/doclen the index
stores are the inputs. A KL-divergence / tf-idf-vector-norm per doc is
computable from postings.

### 3. Structural/character anomaly — "looks unlike normal text"
High-entropy tokens (base64 blobs, hashes), unusual character n-grams. The
**trigram index** over the vocabulary is a partial view of this — a term whose
trigrams are globally rare is character-anomalous. Weaker signal, but present.

### 4. Semantic/contextual anomaly — "means something unusual"
Requires embeddings / sequence models. **pg_fts cannot do this** — it is
bag-of-words lexical. Be explicit: this is out of scope for a BM25 index; that's
what pgvector/embedding indexes are for. A lexical index catches *novel or rare
wording*, not *novel meaning in familiar words*.

## Can it answer the top-0.1% query QUICKLY? — the honest performance picture

This is where design meets the index's actual access paths.

**The idf lookup is instant; the aggregation is the cost.** idf(t) is O(1) from
df. But "top-0.1% documents by max-idf-over-their-terms" needs, in the naive
form, a per-document aggregate over every document's term set — an O(corpus)
pass. That is NOT what an inverted index makes cheap: the index is term→docs, but
this query is doc→terms→idf→aggregate. Three regimes:

- **Precomputed per-doc score (fast query, index/write cost):** if a per-doc
  surprise score were materialized at index/build time (each posting already
  knows its doc's terms as they're inserted), the top-0.1% is then a trivial
  ORDER BY on a stored column — millisecond query. This is the design that makes
  the "top 0.1% anomalous" query fast: **compute surprise at ingest, store it,
  rank on it.** It's an additive per-doc scalar, cheap to maintain, and it turns
  the anomaly query into a sort.
- **Rare-term-driven (fast for the top end):** the *most* anomalous docs are, by
  definition, those containing the rarest terms — and the rarest terms have the
  SHORTEST posting lists. So "documents containing any term with df ≤ k" is
  answered by scanning only the short tail of the dictionary (terms with tiny
  df) and unioning their (few) postings — cheap, and it directly surfaces the
  hapax/near-hapax anomalies. This is genuinely fast because the index is sorted/
  scannable by term and the rare terms are cheap to enumerate. **This is the
  strongest "quick answer" pg_fts could give with little new machinery:** walk
  the dictionary for low-df terms, emit their docs. The top 0.1% by rarity ≈ the
  docs hanging off the rarest terms.
- **Full per-doc ranking (slow, naive):** ranking ALL docs by a mean-idf score
  with no precomputation is an O(corpus) scan — seconds+ at 20M, not a
  low-latency answer. Don't promise this form.

**The inverse ("least anomalous / most typical") is harder to make fast** than
the top-end: "typical" docs are made of common terms with LONG posting lists, so
there's no short-list shortcut — it needs the per-doc aggregate. The
precomputed-score design handles both ends symmetrically; the rare-term
shortcut only helps the anomalous end.

## What a design would look like (sketch, not a proposal to build)

1. **Cheapest, no format change:** a SQL/function layer that, given the index,
   enumerates low-df terms from the dictionary and returns their documents —
   "entries containing globally rare terms," ranked by min df / max idf. Reuses
   existing dictionary scan + df. Answers the *anomalous* end quickly; not the
   typical end. Could ship as an `fts_rare_docs(index, df_threshold)` SRF.
2. **Fast both-ends, needs a per-doc surprise column:** materialize
   `surprise(d)` (e.g. mean or max idf, or a tf-idf norm) at index build/insert
   time. Top/bottom 0.1% become an ORDER BY. Cost: a per-doc scalar to maintain
   (idf drifts as the corpus grows, so the score is approximate unless
   recomputed at merge — acceptable for anomaly ranking, which is relative).
3. **The mixed-corpus angle (ties to the 20M benchmark):** a single index over
   Wikipedia + JSON logs + reviews is a natural anomaly testbed — a JSON log line
   with a novel UUID/stack-trace among prose has extreme max-idf and stands out
   immediately by definition 1. The diversity the benchmark builds is exactly
   what makes anomaly signal visible.

## Honest limitations to state up front

- **Lexical only.** Catches rare/novel *wording and tokens*, not semantic
  novelty. A perfectly-worded-but-semantically-weird log line is invisible.
- **Anomaly ≠ importance.** High idf flags UUIDs, timestamps, and typos as
  "anomalous" — often noise, not signal. Useful for logs (novel identifiers ARE
  the interesting anomalies) but needs tuning (e.g. ignore purely-numeric/high-
  entropy tokens, or the trigram view to down-weight hash-like terms).
- **Fast only with precomputation or a rare-term shortcut.** The naive "rank all
  docs by a corpus-relative score" is an O(N) scan, not an index lookup. The
  index makes the *inputs* (idf, per-doc terms) available; making the *query*
  low-latency needs either the low-df dictionary walk (anomalous end only) or a
  materialized per-doc score (both ends).
- **The "top 0.1%" is a global aggregate**, and inverted indexes are built for
  term-selective retrieval, not whole-corpus ranking — so this is a natural fit
  only in the precomputed-score or rare-term-tail forms above.

## Verdict

Yes, conceptually: pg_fts already stores the lexical-rarity signal
(idf/df/per-doc tf), and a BM25 index is a reasonable substrate for *lexical*
anomaly detection — most naturally "documents containing globally rare terms,"
which the rare-term (low-df) dictionary tail answers quickly with minimal new
machinery, and which the mixed 20M corpus would showcase. Making the general
"top/bottom 0.1% by a corpus-relative surprise score" a low-latency query needs
a materialized per-doc surprise column (an additive index feature). It is a
credible, differentiated direction — an inverted index that also says "here are
the weird ones" — with two honest caveats: it is lexical (not semantic), and
"anomalous" needs token-class tuning so it flags novel errors, not every UUID.
Not building it now (per instruction); recorded as a design direction.
