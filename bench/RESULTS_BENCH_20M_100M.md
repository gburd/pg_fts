# pg_fts 3-way FTS benchmark — 20M and 100M documents (diverse mixed corpus)

**Status: IN PROGRESS — written incrementally during the run.** Tables fill in
as each phase completes so a cutoff still yields partial results.

This is a public-facing, reproducible 3-way (really 4-engine) comparison of the
PostgreSQL BM25 full-text-search extensions at two scales, back-to-back on one
EC2 instance. Methodology rigor is the point; where pg_fts loses, it loses on
the record.

---

## Corpus composition — 20M scale

One `docs(id bigint, title text, body text)` table. Each source is id-offset
into its own range (wiki native <1e9, httplog +1e9, stackoverflow +2e9, c4 +3e9)
so ids stay unique. Invalid UTF-8 stripped with `iconv -c`; C0 control bytes
(NUL, 0x01, etc., except tab) stripped with `tr` (PostgreSQL rejects NUL in
text, and 0x01 is the CSV QUOTE/ESCAPE sentinel). Loaded
`FORMAT csv, DELIMITER E'\t', QUOTE E'\x01', ESCAPE E'\x01'`.

| source | docs | avg body len (chars) | what it stresses |
|--------|-----:|---------------------:|------------------|
| wiki (Wikipedia 20231101.en, all) | 6,407,814 | 3,041 | long natural-language prose |
| httplog (ES Rally `http_logs`, JSON lines) | 8,000,000 | 134 | high-cardinality tokens (IPs, URLs) — vocabulary blow-up |
| c4 (allenai/c4 en, web text) | 3,600,000 | 2,152 | messy web prose |
| stackoverflow (mikex86/stackoverflow-posts) | 2,000,000 | 626 | code + Q&A mixed tokens |
| **total** | **20,007,814** | | multi-modal doclen (134–3041) |

- Assembled TSV: **29 GB**. `COPY` load of 20,007,814 rows: **511 s**; 0 rows lost.
- Heap after load: **21 GB** total relation size (10 GB main fork).
- This is the same source mix as the prior `RESULTS_20M.md` run (wiki 6.4M +
  httplog 8M + so 2M), with c4 3.6M as the web-prose component.

---

## Provenance

| item | value |
|------|-------|
| date | 2026-07-12 (us-east-2) |
| instance | **r7i.24xlarge** (96 vCPU Intel Xeon Platinum 8488C / Sapphire Rapids, 743 GB RAM) |
| instance id | (terminated) |
| storage | 2 TB gp3 (16000 IOPS, 1000 MB/s) mounted at `/data`; PGDATA + corpus on `/data` |
| OS | Fedora Cloud 43 (kernel 7.1.3-100.fc43) |
| PostgreSQL | 17.10, built from source: `./configure --prefix=/data/pg --without-icu CFLAGS=-O2` |
| pg_fts | **0.3.2** (HEAD 03eb8313f8c5ed2b00b4d21ab8bf708cfb72d73e) |
| VectorChord-bm25 | (built from HEAD — commit recorded below) |
| pg_textsearch | (Timescale — version recorded below) |
| ParadeDB pg_search | not included in primary sweep (Tantivy en_stem differs by design; noted) |

### PostgreSQL GUCs (identical across all engines)

```
shared_buffers = 384GB              (~half of 743 GB RAM)
maintenance_work_mem = 16GB
work_mem = 256MB
jit = off
autovacuum = off                    (during runs)
max_parallel_workers = 16
max_parallel_maintenance_workers = 8
max_parallel_workers_per_gather = 8
max_worker_processes = 32
max_wal_size = 32GB
checkpoint_timeout = 60min
wal_compression = on
fsync = on
```

### Measurement contract

- ONE engine measured at a time (never concurrent — cache thrash inflates numbers).
- Latency = **median of 9 warm runs**, discarding 1 warm-up. Cache warmed first.
- Every ranked/count plan **EXPLAIN-confirmed** to use the intended index path
  (Index Scan…Order By / Bitmap Index Scan / Custom Scan FtsCount), not a silent
  seq-scan fallback. Forced with `enable_seqscan=off` (+ `enable_bitmapscan=off`
  for ordering scans, `max_parallel_workers_per_gather=0` where noted).
- `VACUUM docs` + per-index compaction (pg_fts: `fts_vacuum`) BEFORE measuring
  (pending lists aren't ranked; unfair otherwise).
- Analyzers matched: pg_fts + pg_textsearch use PostgreSQL `english` (Snowball);
  VectorChord uses `to_tsvector('english',…)`. ParadeDB (if shown) uses Tantivy
  `en_stem` — its counts are **not directly comparable** and are marked so.
- pg_fts is expected to be 2–5× slower ranked and larger on disk than
  pg_textsearch / VectorChord. That is reported honestly; pg_fts's real edges
  (index-native `count(*)`/`fts_count`, phrase/NEAR/boolean/regex, positions)
  are stated as capability differences, never as latency "wins."

---

---

## Run outcome — STOPPED before measurement (no latency/size/count/NDCG numbers)

This run was **cancelled by the operator ~1.5 h in**, during the pg_fts
`positions=off` index build, before any measurement phase. What completed:

- PostgreSQL 17.10 built; cluster up on `/data` with the GUCs above.
- All 4 engines built: pg_fts 0.3.2, pg_textsearch 1.4.0-dev, VectorChord-bm25
  HEAD `14fc2a332b665e1f38eb5d59bb85c8ac1a00490d` (needed `rustfmt` added to the
  toolchain to build).
- 20M corpus assembled + loaded (20,007,814 docs, 21 GB heap, 0 rows lost).

**No ranked/count/NDCG numbers were captured**, so this file is provenance +
corpus + methodology only. The instance and all its resources (including a VPC +
subnet + IGW + route table that had to be created — the account has no default
VPC in us-east-2) were terminated/deleted at cancellation.

### One finding worth keeping

The pg_fts `positions=off` build at **diverse 20M** was running well past 80 min
(still in the single-threaded merge tail) — **much slower than the ~21 min build
of the prior all-Wikipedia-ish 20M** in `RESULTS_20M.md`. The cause is the
httplog JSON component: ultra-high-df tokens (e.g. `clientip`, df ≈ 8M) produce
enormous posting lists whose serial merge dominates. This is consistent with, and
extends, the two build-scale items already on record:
1. the >`MaxAllocSize` build allocation (fixed in-tree with the Huge variants), and
2. the superlinear trigram sparsemap build at large diverse vocabularies (open).

Net: **build time (not query latency) is pg_fts's weak axis on high-cardinality
JSON-log corpora.** A faster single-threaded merge tail (or parallelizing it) is
the highest-value build-side improvement for the log-search use case. This should
be measured explicitly if/when the full 20M+100M sweep is rerun.

### To resume

Re-dispatch the same plan (this file's provenance + measurement contract are the
spec). The on-box tooling (`sweep.py`, `counts.py`, `qspec_20m.json`, corpus
TSVs, built engines) was lost with the instance and must be rebuilt.
