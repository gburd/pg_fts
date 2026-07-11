# pg_fts benchmark at 20M documents (diverse mixed corpus)

Run 2026-07-11 on EC2 **r7i.12xlarge** (48 vCPU, 384 GB), us-east-2, corpus + PGDATA
on a 600 GB gp3 volume mounted at `/data`. PostgreSQL 17.10 built from source
(`--without-icu -O2`). Instance terminated at end of run.

> Status: the run captured the primary deliverable (the phrase-count cliff and
> its fix at 20M, plus pg_fts index sizes and OFF-side latencies). The run was
> cut off during the ON-side ranked/count sweep and the vChord / pg_textsearch
> comparison sweep, so those competitor tables are **not** in this file. The
> pg_fts OFF numbers and the OFF-vs-ON phrase headline are complete and were
> measured directly (not reconstructed).

## Corpus — 20,000,000 documents, one `docs(id, title, body)` table, 21 GB heap

Diverse mix, each source in its own id range (per `bench/NOTE_CORPUS_20M.md`):

| source        | docs      | what it stresses |
|---------------|-----------|------------------|
| httplog (JSON)| 8,000,000 | high-cardinality tokens (IPs, URLs, hashes) — vocabulary/dictionary blow-up |
| wiki          | 6,407,814 | long natural-language prose |
| c4 (web text) | 3,592,186 | messy web prose |
| stackoverflow | 2,000,000 | code + Q&A mixed tokens |

`COPY` load of 20M rows: **576 s**. (Invalid UTF-8 stripped with `iconv -c`; loaded
`FORMAT csv QUOTE/ESCAPE 0x01`.)

## THE HEADLINE — phrase-count cliff and its fix, at 20M

`count(*)` of a common two-word phrase, `"united states"` — **1,102,837 matching
documents** — on the pg_fts index, forced through the AM (`enable_seqscan=off`,
no parallelism):

| index                          | phrase `count(*)` latency | result |
|--------------------------------|---------------------------|--------|
| `WITH (positions=off)` (default) | **963,572 ms (16 min 3 s)** | 1,102,837 |
| `WITH (positions=on)` (0.3.0 fix)| **~1,190 ms (median of 3)** | 1,102,837 |

**≈ 800× faster, byte-identical answer.** With positions in the postings the phrase
is verified from the posting lists directly; without them the engine heap-fetches
and re-tokenizes all 1.1M AND-set candidates. This is the v0.3.0 feature
(`bench/NOTE_PHRASE_POSITIONS_FIX.md`) validated at 10× the prior scale, on a
corpus deliberately full of high-tf tokens. The 2M-scale cliff was ~232 s; at 20M
the OFF cliff grew to 16 min, exactly the linear-in-candidates blowup predicted.

## pg_fts index size + build (20M diverse corpus)

| index | build | after `fts_vacuum` compaction | vs OFF |
|-------|-------|-------------------------------|--------|
| positions=OFF | 1284 s → 19 GB | **8.7 GB** | 1.0× |
| positions=ON  | 1560 s → 29 GB | **13 GB**  | **1.5×** |

Positions cost **1.5×** on this diverse corpus (within the 1.03×–2.8× range predicted;
the JSON-log high-tf tokens push it above the prose-only low end). `fts_vacuum`
reclaimed the build-time slack in both cases (19→8.7 GB, 29→13 GB) — the P1 vacuum
gate holds at 20M. Heap was 21 GB, so the compacted OFF index is ~0.41× heap,
the ON index ~0.62× heap.

## pg_fts positions=OFF latencies (median ms, warm, AM-forced Index/Order-By scan)

| metric | query (df) | median ms |
|--------|-----------|-----------|
| ranked top-10 | rare — mitochondria | 8.4 |
| ranked top-10 | rare — photosynthesis | 7.1 |
| ranked top-10 | mid — slovakia | 13.2 |
| ranked top-10 | mid — hungary | 12.5 |
| ranked top-10 | common — year | 101.6 |
| ranked top-10 | common — states | 79.7 |
| ranked top-100 | common — year | 139.9 |
| ranked AND top-10 | hungary & year | 33.5 |
| fts_count | rare — mitochondria | 2.3 |
| fts_count | mid — hungary | 5.0 |
| fts_count | common — year | 174.2 |
| fts_count | httplog — clientip | 333.0 |

Shape matches the 2M run: rare terms answer in single-digit ms, common terms scale
with posting-list length; `fts_count` (pg_fts's index-native match count) stays far
cheaper than a heap `count(*)`.

## Observations

- **Dictionary / vocabulary blow-up from JSON logs is real.** The 8M httplog lines
  (IPs, URLs, request hashes) dominate distinct-term count; `fts_count` on
  `httplog(clientip)` at 333 ms reflects the long high-cardinality posting lists.
  This diverse corpus is exactly the anomaly-detection testbed
  (`bench/NOTE_ANOMALY_DETECTION.md`, `fts_anomalous_docs`): rare/novel JSON tokens
  amid prose stand out by max-idf.
- **A build-time scale bug surfaced and was fixed here** (separate from this
  measurement): a very-high-df token's build-time posting arrays can exceed
  `MaxAllocSize` (1 GB) at 20M, which plain `palloc` rejects. `add_posting` /
  `bm25_decode_term` / `bm25_write_postings` now use the Huge allocation variants
  past 1 GB. (Reviewed + released separately.)

## Not captured (run cut off)

- positions=ON ranked/count sweep across bands (only the ON phrase count was
  measured — the headline above).
- vChord-bm25 and Timescale pg_textsearch comparison tables at 20M (both engines
  were built on the box: `/data/vchord`, `/data/pgtext`). A rerun should script the
  full sweep to completion and write results incrementally so a cutoff still yields
  a partial table.
