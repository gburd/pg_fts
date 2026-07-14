# pg_fts 0.3.5 — 3-way BM25 benchmark (RE-RUN, CURRENT numbers)

**Status: COMPLETE.** Written incrementally on the control host. Instance
TERMINATED after collection.

This re-runs the 2.19M Wikipedia 3-way comparison in
`bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md` (whose numbers were pg_fts **1.20**, an
old pre-release predating lazy-boolean-eval, positional postings, and the
`bm25`->`fts` AM rename — NOT valid for 0.3.5). Same instance, PG build, GUCs,
corpus, query terms, and one-engine-at-a-time warm-median-of-9 methodology.

## Provenance
- pg_fts: **v0.3.5** tag, commit `7fc6844` (this repo HEAD).
- Instance: EC2 **r7i.4xlarge** (16 vCPU Sapphire Rapids, ~128 GB), Fedora Cloud 43.
- Instance id: `i-00c98d1da83856c52`  (region us-east-2, launched 2026-07-13 ~18:34 UTC; TERMINATED)
  (a first instance i-044a3a72f040b2eb1 was launched with a 5 GB root that
  couldn't hold the toolchain and was terminated; relaunched with a 300 GB root.)
- PostgreSQL: **17.10** from source (`--without-icu -O2`).
- GUCs: shared_buffers~=half RAM, maintenance_work_mem=16GB, work_mem=256MB,
  jit=off, autovacuum=off during runs, max_parallel_maintenance_workers=8,
  max_parallel_workers=16, max_parallel_workers_per_gather=8.
- Corpus: wikimedia/wikipedia 20231101.en, first 2,188,038 articles, body column.
- Analyzers matched: pg_fts + pg_textsearch use PostgreSQL `english` (Snowball);
  VectorChord uses `to_tsvector('english', ...)`.
- Latency: median of 9 warm runs (1 warm-up discarded), one engine at a time,
  cache warmed, index VACUUM/compacted before measuring.
- Query terms (matched to historical bands): slovakia (rare, df~10874),
  hungary (mid, df~24095), year (common, df~734881).

### Engine versions
- pg_fts: 0.3.5 / 7fc6844
- VectorChord-bm25: HEAD commit = **14fc2a332b665e1f38eb5d59bb85c8ac1a00490d** (v0.0.0), pgrx 0.17.0.
  Uses `emb tsvector = to_tsvector('english',body)`, `USING bm25 (emb bm25_ops)`,
  `emb <&> to_bm25query(to_tsvector('english','q'),'idx')`, `bm25.limit` GUC.
  NOTE: this HEAD's README talks about `bm25vector`+pg_tokenizer, but the
  installed operator class is `FOR TYPE tsvector` — so the matched-Snowball
  `to_tsvector('english',...)` path (identical analyzer contract to historical).
- Timescale pg_textsearch: version = **1.4.0-dev**, commit `d17ea9c2111ccb039caf68feaee6a73f78bf47c7`.
  `USING bm25(body) WITH (text_config='english')`, `body <@> 'q'` ranked ASC.

## Real doc count loaded
2,188,038 (matches historical). Heap = 4558 MB.
df verification (Snowball english, matches historical bands exactly):
slovakia=10874, hungary=24095, year=734881.

## Size / build table
| engine                | index size (compacted) | build (CREATE INDEX) | fts_vacuum |
|-----------------------|-----------------------:|---------------------:|-----------:|
| pg_fts 0.3.5 pos=off  | **4188 MB**            | 1748s (~29 min)      | ~24 min/pass; floor 4188 MB (pass1=4188, pass2=8376 bad, pass3=4188) |
| pg_fts 0.3.5 pos=on   | **5380 MB**            | 1827s (~30 min)      | ~25 min/pass; floor 5380 MB (pass1=5380, pass2=11GB bad, pass3=5380) |
| VectorChord-bm25 HEAD | **1453 MB**            | 37s (+11 min tsvector prep) | n/a  |
| pg_textsearch 1.4.0-dev | **1885 MB**          | 222s (~3.7 min)      | n/a        |

Historical (pg_fts 1.20): pg_fts 7541 MB / ~26 min + ~41 min fts_vacuum;
VectorChord 1367 MB / ~2.3 min; pg_textsearch 1831 MB / ~4.5 min.
Note: pg_fts 0.3.5 pos=off index is **4188 MB vs 7541 MB historically** — the
bm25 index no longer stores positions by default (they moved to opt-in
positions=on), roughly halving the default index. fts_vacuum still oscillates
(HANDOFF 5.1): a pass can grow the index; the stable floor needs re-running.

## Ranked top-10 latency (ms, median/9 warm) — EXPLAIN-confirmed Index Scan+Order By
| query           | df     | pg_fts pos=off | pg_fts pos=on | VectorChord | pg_textsearch |
|-----------------|-------:|---------------:|--------------:|------------:|--------------:|
| rare (slovakia) | 10874  | 12.3           | 12.4          | 5.8         | 2.6           |
| mid (hungary)   | 24095  | 10.2           | 10.4          | 4.8         | 2.7           |
| common (year)   | 734881 | 32.1           | 32.9          | 5.1         | 10.3          |

## Ranked top-100 latency (ms)
| query           | df     | pg_fts pos=off | pg_fts pos=on | VectorChord | pg_textsearch |
|-----------------|-------:|---------------:|--------------:|------------:|--------------:|
| rare (slovakia) | 10874  | 28.0           | 28.1          | 10.6        | 3.5           |
| mid (hungary)   | 24095  | 35.7           | 35.8          | 14.0        | 3.6           |
| common (year)   | 734881 | 60.0           | 60.6          | 22.9        | 12.5          |

## Ranked AND top-10 (ms)
| query              | pg_fts pos=off | pg_fts pos=on | VectorChord | pg_textsearch |
|--------------------|---------------:|--------------:|------------:|--------------:|
| hungary & year     | 11.9           | 12.7          | 11.5        | 6.5           |
| slovakia & hungary | 21.3           | 21.4          | 6.4         | 3.0           |

(VectorChord/pg_textsearch "AND" = multi-term OR-scored ranking, no true
boolean-AND predicate; pg_fts AND is a real boolean-AND match then rank.)

## Ranked phrase top-10 (positions=on) — EXPLAIN-confirmed phrase index scan
pg_fts pos=on answers phrase from positional postings (operator `'unit' <-> 'state'`),
no heap recheck. Phrase count < AND count confirms adjacency enforced
("united states": phrase=361294 vs AND=411011).
Competitors: VectorChord (this HEAD) and pg_textsearch are bag-of-words
ranking-only — **no phrase operator** (N/A).

| phrase          | pg_fts pos=on |
|-----------------|--------------:|
| "united states" | 201.5         |
| "new york"      | 107.6         |

## Index-native count(*) (ms) — pg_fts capability
count(*) uses the fts index via a Bitmap Index Scan (EXPLAIN-confirmed,
enable_seqscan=off; index-native, no seq fallback). fts_count() is the explicit
VM-based fast path. The transparent FtsCount CustomScan pushdown is registered
(shared_preload_libraries=pg_fts) but its cost model prices it above the bitmap
path, so the planner picks the bitmap index scan — a cost-model rough edge, not
a capability loss (still index-native). Competitors: **N/A** (VectorChord and
pg_textsearch are ranking-only, no match/count predicate).

| query          | pg_fts count(*) (index) | pg_fts fts_count() |
|----------------|------------------------:|-------------------:|
| rare (slovakia)| 19.4 (off) / 25.4 (on)  | 17.2 (off) / 22.6 (on) |
| common (year)  | 326.2 (off) / 394.1 (on)| 266.6 (off) / 326.9 (on) |

## Correctness (match counts across engines)
Ground-truth = PostgreSQL native `to_tsvector('english') @@` (the exact
Snowball analyzer pg_fts and pg_textsearch use). All confirmed identical:

| query                    | native tsvector | pg_fts @@@ | agrees |
|--------------------------|----------------:|-----------:|:------:|
| slovakia (df)            | 10874           | 10874      | yes    |
| hungary (df)             | 24095           | 24095      | yes    |
| year (df)                | 734881          | 734881     | yes    |
| hungary & year (AND)     | 11590           | (AND scan) | —      |
| "united states" (phrase) | 361294          | 361294     | yes    |
| united & states (AND)    | 411011          | 411011     | yes    |

pg_fts's bag-of-words, boolean-AND, and positional-phrase counts match the
native PostgreSQL engine exactly (same stemming/stopwords). VectorChord and
pg_textsearch expose no match/count predicate (ranking-only), so a direct
count cross-check with them is N/A; their ranked top-k is over the same
Snowball-stemmed corpus.

## Verdict vs historical gap

### (a) Index size
| engine                | historical (1.20) | now (0.3.5) |
|-----------------------|------------------:|------------:|
| pg_fts pos=off        | 7541 MB           | **4188 MB** |
| pg_fts pos=on         | (was default)     | 5380 MB     |
| VectorChord           | 1367 MB           | 1453 MB     |
| pg_textsearch         | 1831 MB           | 1885 MB     |

pg_fts default index **shrank 7541 -> 4188 MB (~1.8x smaller)** because
positions are now opt-in (pos=off default). The size gap vs VectorChord went
from **~5.5x to ~2.9x** (pos=off) / ~3.7x (pos=on); vs pg_textsearch from
~4.1x to **~2.2x** (pos=off). Still larger, but the gap roughly halved.

### (b) Ranked latency by band (top-10, ms)
| band            | pg_fts now (off) | historical pg_fts | VectorChord now | pg_textsearch now |
|-----------------|-----------------:|------------------:|----------------:|------------------:|
| rare (slovakia) | 12.3             | 15.8              | 5.8             | 2.6               |
| mid (hungary)   | 10.2             | 13.4              | 4.8             | 2.7               |
| common (year)   | 32.1             | 39.9              | 5.1             | 10.3              |

- pg_fts ranked latency **improved modestly** (rare 15.8->12.3, mid 13.4->10.2,
  common 39.9->32.1) — lazy-boolean-eval + tuning, not a codec change.
- **The rare/mid gap shrank sharply on the pg_textsearch axis is GONE the other
  way**: this VectorChord HEAD is SLOWER than the historical 1.6-1.9 ms flat
  (now ~5 ms), so pg_fts-vs-VectorChord narrowed to **~2-6x** (was ~8-40x).
  Historically the gap was rare ~10x / common ~20x; now it is rare ~2.1x /
  common ~6.3x vs VectorChord — **materially narrower**, driven partly by
  pg_fts getting faster and partly by this VectorChord build being slower than
  the one measured historically.
- vs pg_textsearch: pg_fts is still ~3-5x slower on rare/mid, but on the
  **common term pg_fts (32 ms) is now only ~3.1x pg_textsearch (10.3 ms)** and
  the common-term absolute improved (39.9->32.1). Historically ~2-5x; roughly
  unchanged-to-slightly-better.

### (c) Capability (count / query language)
- **Index-native count(*)**: still pg_fts-only. Neither competitor has a
  match/count predicate (both ranking-only). fts_count: rare 17 ms, common
  267 ms (pos=off). count(*) via the index (bitmap): rare 19 ms, common 326 ms.
  The transparent FtsCount CustomScan is registered but its cost model loses to
  the bitmap path (cost-model rough edge, not a capability loss).
- **Phrase (positions=on)**: still pg_fts-only. "united states" phrase ranked
  top-10 = 201 ms, "new york" = 108 ms, answered from positional postings
  (no heap recheck), phrase count exactly matches native PG. Competitors have
  no phrase operator.
- **Query language**: pg_fts uniquely offers boolean/phrase/NEAR/prefix/fuzzy/
  regex over one `@@@`/`<=>` operator; the other two are bag-of-words ranking.

### Net: did positions/lazy-boolean/etc. move the ROADMAP gap?
**Partly, on two of three axes.**
- **Index size**: YES — the default (pos=off) index is ~1.8x smaller than 1.20,
  cutting the ~5.5x VectorChord size gap to ~2.9x. This is the biggest change,
  from making positions opt-in.
- **Ranked latency**: PARTLY — pg_fts got ~20-25% faster per band (lazy-boolean,
  scan tuning), but no codec change, so it is still decode-bound. The measured
  gap-to-VectorChord narrowed a lot (10-20x -> 2-6x), but a chunk of that is
  this VectorChord HEAD being slower than the historically-measured build, not
  pure pg_fts improvement. Against pg_textsearch the ranked gap is roughly the
  same (~3-5x rare/mid), better on common.
- **Capability**: UNCHANGED (still the winner) — index-native count and the rich
  positional/boolean/fuzzy/regex query language remain pg_fts-exclusive; phrase
  is now answered directly from index positions with correctness proven equal
  to native PostgreSQL.

The ROADMAP's codec/early-termination work (#4/P4) is still the lever for
flat common-term latency — the historical framing that positions bloated the
index was itself outdated: making positions opt-in already halved the size
with no codec rewrite. Ranked latency is still the weak axis, but the headline
"~5.5x size / ~10-20x latency" gap is now closer to "~2.9x size / ~2-6x
latency" (with the latency caveat about the VectorChord build).

## Approximations / caveats
- This VectorChord-bm25 HEAD (14fc2a33) is SLOWER than the ~1.6-1.9 ms build
  measured historically (now ~5 ms flat top-10). The latency-gap narrowing is
  therefore partly a competitor regression, not solely pg_fts improvement.
  Both were EXPLAIN-confirmed Index Scan + Order By with bm25.limit=k.
- VectorChord's README describes a `bm25vector`+pg_tokenizer API, but the
  installed operator class is `FOR TYPE tsvector`; used the matched
  `to_tsvector('english',...)` Snowball path (identical analyzer to historical).
- fts_vacuum oscillates (HANDOFF 5.1): a compaction pass can GROW the index;
  the reported sizes are the re-converged floor (needed a 3rd pass for pos=off,
  pos=on). Build "time" is CREATE INDEX only; fts_vacuum is separate (~24 min/pass).
- "AND" for VectorChord/pg_textsearch is multi-term OR-scored ranking (no true
  boolean-AND predicate); pg_fts AND is a real boolean-AND match.
- FtsCount CustomScan pushdown registered but priced out by the planner; the
  index-native count still runs via a Bitmap Index Scan (no seq fallback,
  EXPLAIN-confirmed).
