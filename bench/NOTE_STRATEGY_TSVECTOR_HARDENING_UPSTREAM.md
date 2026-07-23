# pg_fts: tsvector support, production-hardening focus, benchmark plan, and
# upstreaming to core PostgreSQL (2026-07)

Answers to: (1) does pg_fts support tsvector? (2) what to tighten for
production-at-scale/under-load? (3) how to benchmark the competitive
dimensions? (4) could this become a core PostgreSQL feature?

## 1. tsvector support -- behavioral yes, structural no (and a cheap on-ramp)

pg_fts indexes the `ftsdoc` type (opclass `ftsdoc_fts_ops DEFAULT FOR TYPE
ftsdoc USING fts`); you build `CREATE INDEX ... USING fts (to_ftsdoc('english',
body))`. It does NOT index a `tsvector` column directly (no tsvector opclass, no
tsvector->ftsdoc cast). `to_ftsdoc('cfg', text)` uses the SAME PostgreSQL text-
search dictionaries/parser as `to_tsvector`, and `@@@` counts match native
`to_tsvector @@ to_tsquery` exactly (proven in the suite across scripts) -- so
it's behaviorally a tsvector superset, but an existing `tsvector` COLUMN can't
feed the index as-is.

GAP + fix: add a `to_ftsdoc(tsvector)` overload (tsvector already carries
lexemes + positions, so it maps cleanly to ftsdoc v3). This is VectorChord's
adoption on-ramp -- lets a shop with a materialized `tsvector` column adopt
pg_fts without re-analyzing from source. Low-risk, format-preserving, on-mission
(PG-native interop). Roadmap it.

## 2. Production-hardening focus (ordered by value), from our own audits + the
##    six field reports

Correctness/operability under concurrency (highest):
- **A1 scan-vs-merge page recycle (OPEN, confirmed):** scans hold no scan-
  duration pin and there is no nbtree/GIN-style deletion-XID recycle gate, so a
  concurrent merge + insert can recycle a page a scan is mid-read -> bounded
  wrong result under load. The one correctness-under-load gap. Fix: a recycle
  gate (stamp freed pages, refuse reuse until no older snapshot) or scan-
  duration segment pinning; needs the t/005 concurrency repro to gate it.
- **Interrupt coverage:** pg_fts had zero CHECK_FOR_INTERRUPTS pre-vacuum-fix;
  scan/decode/CIC-validation loops still have gaps -> the un-cancellable spins
  users hit. Systematic audit of every O(corpus) loop. (PG-core RelationTruncate
  / parallel-error-propagation stay partly outside our reach -- document those.)

Contention/throughput under write load:
- **Metapage EXCLUSIVE lock on every INSERT** serializes all writers
  (concurrency audit finding 1.1) -> INSERT throughput collapses under many
  concurrent writers. Fix: a GIN-fastupdate-style per-inserter fast path.

Memory/robustness (build path now bounded by 1.0.5/1.0.6; residual):
- **Unbounded OR-set materialization:** a broad boolean OR builds the full TID
  union in memory -> spike on many-high-df-term OR over a huge corpus. Fix:
  streaming boolean evaluation.

Size/latency (the competitive axes -- already on ROADMAP):
- doclen sidecar (~40% smaller), impact-ordered postings + hard top-k (flat
  common-term latency), parallel-merge-at-scale verification + build-time docs.

## 3. Benchmark plan -- see bench/PLAN_4WAY_BENCHMARK.md
4-way (pg_fts, ParadeDB pg_search NEW, pg_textsearch, VectorChord) + native
baseline. The methodology fix that matters: use a STORED ftsdoc/tsvector column
(`ORDER BY col <=> q`), not the expression-index form (`ORDER BY to_ftsdoc(body)
<=> q`) whose per-row re-analysis was 40-88% of prior "latency." Measure the
full matrix: size, build time + PEAK build memory, ranked latency (stored form),
**ranked QPS under concurrency (never measured)**, capability grid, correctness,
**concurrent-write+query correctness (the A1 scenario)**, and recall/NDCG. The
matrix will confirm the focus list in section 2: doclen sidecar (size),
impact-ordering (latency), metapage fastpath (write QPS), A1 (correctness under
load).

## 4. Upstreaming to core PostgreSQL -- realistic assessment

Short version: **the parts that make sense to upstream are small, specific core
enablers -- NOT "put pg_fts's bm25 AM in core."** The archive shows no active
core BM25 proposal; the ecosystem deliberately pushes FTS-ranking innovation to
extensions, and the index-AM extension API exists precisely so a BM25 AM does
NOT need core changes. pg_fts, pg_textsearch, VectorChord, pg_search all ship as
extensions for that reason. So the framing isn't "merge the AM"; it's "what
core gaps did building pg_fts expose that, if fixed in core, would make EVERY
FTS/BM25 extension better?"

What NOT to propose:
- The bm25 AM itself. Core adds a full new index AM only rarely (BRIN was the
  last, ~2015) and only with a champion + sustained committer interest + broad
  need. A single-maintainer extension AM competing with 3+ others is not that.
  Timescale pg_textsearch (C + PostgreSQL license) is the more upstreamable-
  shaped candidate if anyone drives "native default BM25," and even that is a
  long road.

What IS worth proposing to -hackers (small, general, extension-agnostic):
1. **Corpus-statistics access for ranking.** BM25 needs N (doc count), avgdl,
   and per-term df. Today every BM25 extension re-derives/stores these itself.
   A core hook or catalog surface for "index-maintained scalar/aggregate
   statistics an AM can expose to the planner/executor" would help all of them.
   Frame as a generalization, backed by our concrete need.
2. **A recyclable-page discipline the AM API blesses.** Our A1 gap (no
   deletion-XID recycle gate) is one nbtree/GIN each solved privately. A
   documented, reusable "page is recyclable only after GlobalVis says no scan
   can hold it" helper in the AM/bufmgr layer would stop every new AM from
   re-implementing (and mis-implementing) it. This is the highest-quality
   thing our work surfaced: a real, general correctness footgun.
3. **CHECK_FOR_INTERRUPTS / progress-reporting ergonomics for long AM builds.**
   The un-cancellable-spin and the blocks_done-freezes-at-75% gaps are partly
   that pg_stat_progress_create_index's phases don't fit a
   scan-then-merge-then-compact AM. A way for an AM to report custom build
   phases/progress would help GIN/GiST/BRIN builds too.
4. **`MemoryContextMemAllocated` recurse-default footgun (docs/API).** Our 1.0.5
   bug was `false` (don't recurse) missing a child dynahash. Worth a
   documentation note / assertion helper; several in-core callers have the same
   trap. Small, but a real lesson.
5. **BM25/ranking as a documented pattern, not code.** The most likely "core"
   outcome is doc/advocacy: a canonical "how to do relevance ranking on
   PostgreSQL" guide that points at the extension ecosystem, plus any small
   enablers above -- not core code.

Recommended path if pursued: start a low-key -hackers thread on ONE enabler
(the recyclable-page discipline, item 2 -- it's general, correctness-flavored,
and not tied to selling pg_fts), grounded in the concrete AM need, and see if it
draws a committer. Do NOT lead with "here is my BM25 AM for core." Search prior
-hackers threads for each enabler before proposing (per project steering).
