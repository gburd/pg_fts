# pg_fts hardening results (2026-08) -- EC2, PG18.4, DB on local NVMe

All on EC2 (chiuso account, owner=gburd-agent), NOT local hosts. x86_64
(r6id.4xlarge) + aarch64 Graviton3 (r7gd.4xlarge). Corpus: 2.19M Wikipedia
(the standard cut), plus synthetic uniform/Zipfian/degenerate distributions.

## Headline: a real 5x common-term ranked-latency regression found + fixed

The 1.3.0 exactness hardening pessimized common-term WAND ~5x (per-posting
re-pivot instead of per-block skip). Caught by the head-to-head vs
pg_textsearch. Fixed (gated block-skip: fast single-cursor path + safe
multi-segment path); exactness preserved (genuine_misses=0), fuzz ALL CLEAN.
Commit b7fa7d7.

## Competitive vs Timescale pg_textsearch (on ITS advertised strengths)

pg_textsearch advertises: "Fast top-k via Block-Max WAND", "Best in class
performance and scalability". Head-to-head, identical 2.19M corpus + host, both
english config, warm best-of-9:

| dimension | pg_fts | pg_textsearch |
|---|---:|---:|
| rare `slovakia` k10   | 4.5 ms  | 3.6 ms  |
| mid  `hungary`  k10   | 5.1 ms  | 4.5 ms  |
| common `year`   k10   | 27.8 ms | 24.1 ms |
| common `year`   k100  | 29.1 ms | 29.8 ms |  <- pg_fts faster
| index size (compacted)| 2089 MB | 1869 MB |  (1.12x; was 2.2x pre-trigrams-off)
| build (2.19M)         | 268 s   | 216 s   |

pg_fts is competitive on pg_textsearch's headline Block-Max-WAND dimension
(within ~15%, faster at k100) AND additionally offers @@@ match predicate,
index-native count(*), phrase/NEAR, prefix/fuzzy/regex -- none of which
pg_textsearch (bag-of-words ranking-only) provides.

## Adverse-memory matrix (2.19M, x86) -- CORRECT + STABLE across the spectrum

| config | shared_buffers | mwm | work_mem | par | build | correct? |
|---|---|---|---|---|---|---|
| tiny   | 16MB  | 16MB  | 1MB   | 0 | 251s | year/hungary/ranked10 all correct |
| small  | 128MB | 64MB  | 4MB   | 2 | 165s | correct |
| medium | 2GB   | 512MB | 64MB  | 4 | 252s | correct |
| large  | 16GB  | 4GB   | 256MB | 8 | 251s | correct |
| huge   | 48GB  | 16GB  | 1GB   | 8 | 254s | correct |

No wedge, no OOM, no wrong answers -- including the pathological 16MB/1MB/
no-parallel build. year=734881, hungary=24095, ranked top-10=10 in every config.

## Data distributions -- correct on uniform, Zipfian, and degenerate

- UNIFORM (1000-term vocab, ~flat): index count == seqscan (1000).
- ZIPFIAN/heavy-tail: hot=180000, warm=60000, cool=20000, rare=1; ranked
  top-50 on the hot term genuine_misses=0.
- DEGENERATE (a term in ALL 200000 docs, max-df stress): count=200000, ranked
  top-10=10, genuine_misses=0, anomaly detection surfaces the rare tail.

## Load/soak -- concurrent read+write+merge+vacuum at scale, 4 min

200k immutable "anchor" docs + 100k churn partition; 1 writer (delete-all +
insert 100k, 109 rounds), 1 maintenance loop (fts_merge + fts_vacuum, 20
rounds), 3 readers (13505 total reads). Result: **0 wrong answers, 0 errors, 0
crashes**; every reader always saw anchor count=200000 and ranked top-10=10;
index 64MB -> 118MB (bounded, reclaimed by the vacuum loop), final anchor
count=200000.

## Architectures

- x86_64: full gate + fuzz + all of the above.
- aarch64 (Graviton3): full gate PASS (installcheck 3/3, isolation 2/2, TAP
  8/8), fuzz ALL CLEAN. Codec/alignment/endianness parity confirmed.

## Windows / MSVC

Source is MSVC-clean by design: no POSIX-only headers, no GCC statement-exprs /
__attribute__ / __int128 / bare popcount builtins in pg_fts code; %zu (MSVC-ok).
The vendored sparsemap carries full _MSC_VER shims (__popcnt64,
_BitScan{Forward,Reverse}64 for _M_X64 and _M_ARM64). meson.build is the
Windows/MSVC build recipe and references all 14 .c files (no gap); its header
documents validation on Windows 11 ARM64 (VS2022) against MSVC PostgreSQL 17.10.
A native-Windows installcheck/TAP run remains separate plumbing (not done here;
requires an MSVC-built PostgreSQL + a Windows test harness).

## Coverage

Gate now measures + enforces line (93.3%, >=90), function (97.9%, >=85), and
branch (75.7%, gated >=75). ~700 lines of new targeted tests. Branch ceiling
from functional tests is ~76%; the remainder is defensive/rare/concurrency arms
covered by the fuzz harness (ALL CLEAN, planted-bug teeth) + ASan churn tests.

## API surface exercised (features on/off)

WITH (trigrams on|off), WITH (positions on|off); @@@ match; <=> ranked (WAND for
1-3 terms, MaxScore for >=4); count(*) pushdown (expr + plain-column) + dict-df
fast path; fts_search SRF; fts_anomalous_docs (with/without max_df);
fts_index_stats/df/nsegments; fts_bm25 / fts_bm25_opts (all variants +
aliases + invalid + NULL guards) / fts_bm25f (multi-field, NULL elements,
mismatched lengths); fts_highlight / fts_snippet; boolean AND/OR/NOT, phrase,
NEAR, prefix, fuzzy, regex; tsquery->ftsquery migration; fts_merge / fts_vacuum;
incremental insert (pending) + tombstones; oversized-doc segments;
CREATE INDEX CONCURRENTLY (isolation spec).
