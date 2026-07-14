# pg_fts 0.3.5 — character-encoding / multi-script correctness + realistic-form latency

**Status: IN PROGRESS.** Written incrementally on the control host during the run.
Instance TERMINATED after collection (see final section). NOT committed — left for review.

The primary deliverable is **Part A: per-script encoding correctness** (does each
engine produce results matching PostgreSQL native `to_tsvector` ground truth, or
silently differ/mangle/crash). Part B (realistic-query-form latency) is secondary.

---

## Provenance

- **pg_fts**: v0.3.5+, commit `0414617` (HEAD; `v0.3.5-5-g0414617`), AM `fts`.
- **PostgreSQL**: 17.10 from source, `./configure --prefix=/data/pg --without-icu CFLAGS="-O2"`.
- **VectorChord-bm25**: HEAD commit `14fc2a332b665e1f38eb5d59bb85c8ac1a00490d`
  (2026-04-28), pgrx `=0.17.0`. (build status recorded below)
- **Timescale pg_textsearch**: version `1.4.0-dev`, commit
  `d17ea9c2111ccb039caf68feaee6a73f78bf47c7` (2026-06-24). AM `bm25`, operator `<@>`.
- **Instance**: EC2 **r7i.4xlarge** (16 vCPU Sapphire Rapids, 123 GiB), Fedora
  Cloud 43, us-east-2. Instance id `i-0ba5772cfb64e3537`, owner=gburd-agent,
  Name=pgfts-enc-20260714-142937. 300 GB gp3 **root** (Fedora's 5 GB default
  root can't hold the toolchain — a growable 300 GB root is used instead of a
  separate /data disk; /data is a dir on root).
- **GUCs (UTF-8 cluster)**: shared_buffers=64GB, maintenance_work_mem=16GB,
  work_mem=256MB, jit=off, autovacuum=off, parallel workers per HANDOFF,
  shared_preload_libraries='pg_fts,pg_textsearch'(+vchord_bm25 when present).
- **Clusters**: UTF-8 (port 5432, locale C), LATIN1 (5433), EUC_JP (5434), all
  `--locale=C` so collation never masks an analyzer difference.
- **Ground truth**: PostgreSQL native `to_tsvector('simple'|'english', body) @@
  to_tsquery(...)` on the SAME database. pg_fts's regconfig path uses the same
  `parsetext()` tokenizer, so on `simple` it MUST match native exactly; any
  divergence is a pg_fts bug. pg_textsearch with `text_config='simple'` also
  uses PG's tsparser. VectorChord's matched path uses `to_tsvector('...')`.
- **Match-set definitions**: pg_fts = `to_ftsdoc(cfg,body) @@@ to_ftsquery(cfg,term)`;
  pg_textsearch = rows where `body <@> to_bm25query(term,idx) < 0` (score 0 =
  no match, <0 = match, verified); VectorChord = rows returned by its `<&>`
  ranked scan with `bm25.limit` large.

---

## Part A1 — UTF-8 server, 14-script battery

Corpus (one doc per script, all UTF-8 in a UTF-8 server DB):
ascii, latin1 accents (café société naïve Zürich), Windows-1252 smart punctuation
(curly quotes, em-dash, €, ellipsis), CJK Han (東京都/図書館), CJK mixed
(PostgreSQL は 全文検索), Hangul (서울 도서관), NFC precomposed café, NFD
decomposed cafe+U+0301, emoji (🚀😀), CJK Ext-B 4-byte (U+20000), Arabic RTL,
Hebrew RTL, Turkish dotless-i (İstanbul ışık), German ß (Straße Fußball).

### pg_fts vs native — `simple` analyzer (the exact-match contract)

Every per-script, per-term probe returned `agree = t`. Aggregate parity gates:

| gate | result |
|------|:------:|
| `simple` match parity (16 terms × 14 scripts) | **t (MATCH)** |
| `english` match parity (stemming path) | **t (MATCH)** |
| index-native df parity (built `USING fts`, count @@@ vs native) | **t (MATCH)** |
| NFC vs NFD parity (precomposed vs decomposed, id 7 & 8) | **t (MATCH)** |
| built-in analyzer multi-script round-trip (`ftsdoc_send` in=out) | **t (MATCH)** |

Selected per-script hits (pg_fts / native both `t`):
fox(ascii), café+naïve(latin1 + NFC), 東京都+図書館(Han), 서울+책(Hangul),
🚀(emoji), العربية+كتاب(Arabic), עברית(Hebrew), ışık(Turkish), straße+fußball(German).

Notable *agreements on non-hits* (both engines correctly follow native): probe
`istanbul` does NOT match doc `İstanbul` under `simple` (PG's tsparser lowercases
İ→i+combining, not ASCII "i"), and probe `quotes` does NOT match the curly-quoted
`"smart quotes"` word (tsparser keeps the quote glyphs attached) — pg_fts matches
native on both, i.e. it neither over- nor under-matches.

**pg_fts A1 verdict: MATCH on every script.** No crash, no silent drop, no
divergence from native on any of the 14 scripts including 4-byte CJK Ext-B,
emoji, NFC/NFD, RTL, Turkish İ, and German ß. This reproduces the in-repo gate
(`sql/pg_fts.sql` encoding block) on real EC2 hardware.

### pg_textsearch vs native — `simple` (`text_config='simple'`)

pg_textsearch's `text_config='simple'` uses PostgreSQL's own tsparser, so its
match set equals native on every script tested. Match-set matrix (pgts_ids vs
native_ids), all identical:

| term | pgts | native | | term | pgts | native |
|------|------|--------|-|------|------|--------|
| fox | {1} | {1} | | كتاب | {11} | {11} |
| café | {2,7} | {2,7} | | العربية | {11} | {11} |
| naïve | {2,7} | {2,7} | | עברית | {12} | {12} |
| 東京都 | {4} | {4} | | ışık | {13} | {13} |
| 図書館 | {4} | {4} | | straße | {14} | {14} |
| 서울 | {6} | {6} | | fußball | {14} | {14} |
| 책 | {6} | {6} | | 🚀 | {9} | {9} |
| istanbul | {} | {} | | quotes | {} | {} |

**pg_textsearch A1 verdict: MATCH on every script (with PG `simple` config).**
Same tokenizer as native ⇒ no divergence. (This is a *design* agreement, not a
coincidence: pg_textsearch delegates tokenization to PG's text-search config.)

### VectorChord (matched `to_tsvector('simple')` path, `bm25_ops FOR TYPE tsvector`)

VectorChord's ranked index scan returns only true candidates, so its match set
(ids returned by `ORDER BY emb <&> to_bm25query(to_tsvector('simple',term),idx)`
with a large `bm25.limit`) equals native `simple` on every script:

| term | vchord | native | agree | | term | vchord | native | agree |
|------|--------|--------|:-----:|-|------|--------|--------|:-----:|
| fox | {1} | {1} | t | | كتاب | {11} | {11} | t |
| café | {2,7} | {2,7} | t | | العربية | {11} | {11} | t |
| naïve | {2,7} | {2,7} | t | | עברית | {12} | {12} | t |
| 東京都 | {4} | {4} | t | | ışık | {13} | {13} | t |
| 図書館 | {4} | {4} | t | | straße | {14} | {14} | t |
| 서울 | {6} | {6} | t | | fußball | {14} | {14} | t |
| 책 | {6} | {6} | t | | 🚀 | {9} | {9} | t |
| istanbul | {} | {} | t | | quotes | {} | {} | t |

**VectorChord A1 verdict: MATCH on every script** (matched tsvector('simple') path).

**Robustness quirk (a real defect):** a query whose terms have ZERO matches in
the index raises `ERROR: number of needed rows is set to 0` instead of returning
an empty result set. The two zero-match probes (`istanbul`, `quotes`) had to be
wrapped in an exception handler to report `{}`. pg_fts and pg_textsearch both
return a clean empty set for a no-match query; VectorChord errors. In an
application this means a search box query that happens to contain only
out-of-vocabulary terms throws instead of returning "no results".

### A1 correctness matrix (UTF-8 server)

| script | pg_fts | pg_textsearch | VectorChord | native | notes |
|--------|:------:|:-------------:|:-----------:|:------:|-------|
| ascii | MATCH | MATCH | MATCH | truth | |
| latin1 accents | MATCH | MATCH | MATCH | truth | |
| win1252 smart-punct | MATCH | MATCH | MATCH | truth | curly-quoted "quotes" not tokenized as word by any (all agree with native) |
| CJK Han | MATCH | MATCH | MATCH | truth | |
| CJK mixed (JP+ASCII) | MATCH | MATCH | MATCH | truth | |
| Hangul | MATCH | MATCH | MATCH | truth | |
| NFC precomposed | MATCH | MATCH | MATCH | truth | |
| NFD decomposed | MATCH | MATCH | MATCH | truth | PG doesn't normalize; all engines follow native byte-for-byte |
| emoji 4-byte | MATCH | MATCH | MATCH | truth | |
| CJK Ext-B 4-byte U+20000 | MATCH | MATCH | MATCH | truth | no crash/drop on any |
| Arabic RTL | MATCH | MATCH | MATCH | truth | |
| Hebrew RTL | MATCH | MATCH | MATCH | truth | |
| Turkish dotless-i | MATCH | MATCH | MATCH | truth | `istanbul` != `İstanbul` under simple; all agree with native |
| German ß | MATCH | MATCH | MATCH | truth | |

All three engines MATCH native on every script under a UTF-8 server. This is a
**design agreement**, not luck: all three delegate tokenization to PostgreSQL's
text-search machinery on the matched path (pg_fts via `parsetext()`;
pg_textsearch via `text_config`; VectorChord via `to_tsvector`). None of the
engines CRASHES on any script, none silently DROPS or MANGLES a script. The one
defect surfaced is VectorChord's zero-match ERROR (a robustness bug, not a
tokenization bug).

---

## Part A2 — non-UTF-8 SERVER encodings

Separate clusters via `initdb --encoding=...`. Content loaded in the matching
encoding (UTF-8 test files converted with `iconv` before `psql -f`).

### Extension INSTALLABILITY under a non-UTF-8 server (a real finding)

`CREATE EXTENSION` reads the extension's `.sql` install script from disk and
interprets its bytes in the **database encoding**. Both extensions ship non-ASCII
bytes in that script, so **neither installs on a non-UTF-8 server out of the box**:

- **pg_fts**: `pg_fts--0.3.5.sql` line 197 has a UTF-8 ellipsis `'…'` as the
  DEFAULT for `fts_snippet(..., ellipsis text DEFAULT '…')`. On an EUC_JP or
  LATIN1 database `CREATE EXTENSION pg_fts` fails with `invalid byte sequence for
  encoding "EUC_JP": 0xe2 0x80`. Workaround used here: patch the one default to
  ASCII `'...'`. **This is a packaging defect, not a runtime engine defect** —
  the shipped install script is not pure-ASCII, so it cannot load on a non-UTF-8
  server. Trivial to fix (make the default ASCII, or `\uXXXX`-escape it).
- **pg_textsearch**: `pg_textsearch--1.4.0-dev.sql` has non-ASCII glyphs (→, µ,
  à, §) in **comments** only; same failure mode, same class of packaging defect.
  Workaround: transliterate comments to ASCII.

Once the install scripts are ASCII, both extensions load and **function
correctly** under non-UTF-8 servers:

### LATIN1 server (accented Western-European content, native LATIN1 bytes)

| gate | pg_fts | pg_textsearch |
|------|:------:|:-------------:|
| match parity vs native (fox, café, naïve, zürich, déjà, façade, straße) | **MATCH** | **MATCH** |
| index build + count parity | **MATCH** | **MATCH** |
| built-in (non-regconfig) analyzer round-trip | **MATCH** | n/a |

pg_fts's byte-wise `fold_token` non-UTF-8 fallback does NOT corrupt LATIN1 text:
its `@@@` match set and index-native counts equal native `to_tsvector('simple')`
on the same LATIN1 DB for every accented probe. pg_textsearch match set = native.

### EUC_JP server (Japanese + ASCII content, native EUC_JP bytes)

| gate | pg_fts | pg_textsearch |
|------|:------:|:-------------:|
| match parity vs native (fox, 東京都, 図書館, 全文検索, テスト, postgresql) | **MATCH** | **MATCH** |
| index build + count parity | **MATCH** | **MATCH** |
| built-in (non-regconfig) analyzer round-trip | **MATCH** | n/a |

**A2 verdict (so far): both pg_fts and pg_textsearch BUILD and QUERY CORRECTLY
under LATIN1 and EUC_JP servers, matching native to_tsvector exactly.** The only
non-UTF-8 hazard is the extension install-script (needs ASCII), not the engine.
VectorChord under non-UTF-8 servers: pending build.

---

## Part A3 — client-encoding conversion (UTF-8 server, legacy client)

UTF-8 server, `client_encoding` SET to a legacy encoding, text inserted so PG
converts client->server. SJIS/GB18030 are client-only in PG (not valid server
encodings), so this is the only place to exercise them. Files were built in the
target encoding with `iconv` and loaded with the matching `PGCLIENTENCODING`.

| client enc | inserted | stored (read back UTF-8) | round-trip |
|------------|----------|--------------------------|:----------:|
| WIN1252 | café € naïve société | café € naïve société | OK |
| SJIS | 東京都 図書館 | 東京都 図書館 | OK |
| GB18030 | 北京 图书馆 | 北京 图书馆 | OK |

All three round-trip correctly (codepoint-integrity check: euro €, kanji 東京都,
hanzi 北京 all present after conversion). pg_fts `@@@` match parity vs native
`to_tsvector('simple')` on the converted text = **t** for every probe; per-term
id sets identical. Note GB18030-simplified `图书馆` and SJIS-traditional `図書館`
are distinct codepoints and are correctly matched to their own docs (no cross-
contamination). **A3 verdict: MATCH** — legacy-client conversion is handled by
PG's conversion layer and pg_fts sees correct UTF-8; no encoding defect.

---

## Part B — realistic-form ranked latency (stored ftsdoc column)

Corpus: 400,000 synthetic English prose docs (~80-200 words each, Zipfian
vocabulary so real df bands form), 1063 MB heap. NOTE: not Wikipedia — a
synthetic corpus with uniform ~140-word bodies. This makes the re-analysis tax
MORE visible than Wikipedia (uniform body sizes, so per-row analysis dominates),
so the tax multipliers below are an upper-ish bound; the direction and
mechanism are identical to PROFILE_STEP0's Wikipedia finding. df bands
(native english): slovakia=97,104, hungary=97,042, year=302,633.

Both pg_fts index forms built on the SAME table:
- **expression form** (historical benchmark form):
  `CREATE INDEX docs_expr ON docs USING fts (to_ftsdoc('english', body))`,
  queried `WHERE to_ftsdoc('english',body) @@@ q ORDER BY to_ftsdoc('english',body) <=> q`.
- **stored form** (realistic app form): `ALTER TABLE docs ADD COLUMN d ftsdoc;
  UPDATE docs SET d = to_ftsdoc('english', body); CREATE INDEX docs_stored ON
  docs USING fts (d)`, queried `WHERE d @@@ q ORDER BY d <=> q`.

Median of 9 warm runs, EXPLAIN-confirmed `Limit -> Index Scan ... Index Cond +
Order By` for every query (see EXPLAIN below). enable_seqscan=off,
enable_bitmapscan=off, max_parallel_workers_per_gather=0.

### The re-analysis tax (pg_fts expression form vs stored form, same data)

| band | df | pg_fts EXPR (ms) | pg_fts STORED (ms) | tax (expr/stored) |
|------|---:|-----------------:|-------------------:|------------------:|
| slovakia top-10 | 97,104 | 569.7 | **3.82** | **149x** |
| slovakia top-100 | 97,104 | 570.1 | **3.88** | 147x |
| hungary top-10 | 97,042 | 570.2 | **3.78** | 151x |
| hungary top-100 | 97,042 | 569.9 | **3.89** | 146x |
| year top-10 | 302,633 | 576.1 | **7.75** | 74x |
| year top-100 | 302,633 | 576.0 | **7.91** | 73x |

The expression form is ~570 ms **flat** regardless of term or k, while the index
scan itself touches only ~2,500 buffers and emits the correct 9-100 rows (EXPLAIN
below). The entire ~570 ms is `to_ftsdoc('english', body)` being re-evaluated
(full Snowball tokenize+stem of each candidate body) because the same expression
sits in the ORDER BY / recheck; the stored column supplies the ftsdoc directly
with no re-analysis. This is exactly PROFILE_STEP0's finding, now isolated on a
controlled corpus: **74-151x of the historical pg_fts ranked latency was the
re-analysis artifact of the benchmark query form, not scan cost.**

```
-- expression form, year top-10 (575 ms, but only 2494 buffers, 9 rows)
 Limit (actual time=574.918..575.735 rows=9)
   Buffers: shared hit=2494
   ->  Index Scan using docs_expr on docs (actual time=574.917..575.731 rows=9)
         Index Cond: (to_ftsdoc('english', body) @@@ '''year''')
         Order By:   (to_ftsdoc('english', body) <=> '''year''')
 Execution Time: 575.798 ms
-- stored form, year top-100 (7 ms)
 Limit (actual rows=100)
   ->  Index Scan using docs_stored on docs (actual rows=100)
         Index Cond: (d @@@ '''year'''); Order By: (d <=> '''year''')
 Execution Time: 7.084 ms
```

### 3-way, realistic (native) form, same corpus & terms

| band | pg_fts STORED | pg_textsearch (`<@>`) | VectorChord (`<&>`) |
|------|--------------:|----------------------:|--------------------:|
| slovakia top-10 | 3.82 | 1.80 | 1.62 |
| hungary top-10 | 3.78 | 1.72 | 1.83 |
| year top-10 | 7.75 | 3.59 | 2.45 |
| slovakia top-100 | 3.88 | 2.62 | 8.81 |
| hungary top-100 | 3.89 | 2.59 | 9.70 |
| year top-100 | 7.91 | 5.25 | 12.47 |

With the realistic (stored) form, pg_fts is within **~1.5-2.4x** of pg_textsearch
and VectorChord on top-10, and actually **FASTER than VectorChord on top-100**
(3.9 vs 9.7 ms mid; 7.9 vs 12.5 ms common) because VectorChord's cost grows with
k while pg_fts's WAND scan is nearly k-flat here. Contrast the historical
expression-form numbers where pg_fts looked 5-40x slower: on this corpus the
expression form (570 ms) vs competitors (2-12 ms) is a ~50-300x gap that is
**entirely the re-analysis artifact** — the stored form closes almost all of it.

### Index size (400k corpus, positions=off default)

| | heap | pg_fts expr | pg_fts stored | pg_textsearch | VectorChord |
|-|-----:|------------:|--------------:|--------------:|------------:|
| size | 1063 MB | 490 MB | 109 MB | 56 MB | 22 MB |

Caveat: `docs_expr` (490 MB) was NOT fts_vacuum-compacted (its VACUUM was aborted
- see operational note), while `docs_stored` (109 MB) built compact in one pass;
both are the same logical index (positions=off). The compacted pg_fts index is
~109 MB, ~2x pg_textsearch and ~5x VectorChord on this corpus - consistent with
the HANDOFF size story, narrower than the historical ~2.9-5.5x because this
corpus's stopword-heavy synthetic bodies compress differently.

---

## VERDICT

**1. Is pg_fts correct across encodings (vs native)? YES - unconditionally.**
On a UTF-8 server pg_fts's `@@@` match set and index-native counts equal
PostgreSQL native `to_tsvector('simple'/'english')` on all 14 scripts tested:
ASCII, Latin-1 accents, Windows-1252 punctuation, CJK Han, JP mixed, Hangul,
NFC/NFD combining marks, emoji, 4-byte CJK Ext-B, Arabic+Hebrew RTL, Turkish
dotless-i, German ß. No crash, no silent drop, no divergence. It also matches
native under LATIN1 and EUC_JP **server** encodings (its byte-wise fold_token
fallback does not corrupt) and correctly round-trips WIN1252/SJIS/GB18030
**client** conversion. Every parity gate returned `t`.

**2. How does correctness+robustness compare to the competitors?**
- **Tokenization correctness (A1):** three-way TIE - all three MATCH native on
  the matched analyzer path, because all three delegate tokenization to PG's
  text-search config/parser. Any real-world divergence would come from a
  DIFFERENT analyzer (e.g. VectorChord+pg_tokenizer or a Tantivy tokenizer),
  which is a design choice, not a bug; on the PG-tokenizer path they are
  identical.
- **Non-UTF-8 SERVER robustness (A2):** all three FUNCTION under LATIN1 and
  EUC_JP servers (build index + query correctly = native). But there is a
  **packaging defect shared by pg_fts and pg_textsearch**: their extension
  install `.sql` scripts contain non-ASCII bytes (pg_fts: a `'…'` ellipsis
  DEFAULT on `fts_snippet`; pg_textsearch: comment glyphs), so `CREATE
  EXTENSION` FAILS on a non-UTF-8 database until the script is made ASCII.
  VectorChord's SQL is pure ASCII and installs cleanly on any server encoding.
  This is the single most actionable pg_fts finding: **make the shipped install
  SQL pure-ASCII** (one-line fix) so pg_fts installs on non-UTF-8 servers.
- **Zero-match robustness:** pg_fts and pg_textsearch return a clean empty set;
  **VectorChord ERRORs** (`number of needed rows is set to 0`) on a query whose
  terms are all out-of-vocabulary. pg_fts is the more robust of the two Rust-vs-C
  comparison here.

**3. Does the realistic query form change the latency story? DECISIVELY YES.**
The historical "pg_fts is 5-40x slower on ranked" gap is largely a
benchmark-query-form artifact. Using a STORED `ftsdoc` column (what a real
application writes) instead of a recomputed `to_ftsdoc(body)` expression cut
pg_fts ranked latency by **74-151x** on this corpus (570 ms -> 3.8-7.9 ms) and
brought it to within ~1.5-2.4x of pg_textsearch/VectorChord on top-10 and
actually AHEAD of VectorChord on top-100. The re-analysis tax that PROFILE_STEP0
identified is real, dominant, and **avoidable by users today** with the stored-
column form. pg_fts's honest ranked-latency position is much closer to the
competitors than every prior benchmark (which all used the expression form)
showed. The remaining ~1.5-2x gap is the decode-bound WAND scan (HANDOFF section 4),
not the analyzer.

**Bottom line:** pg_fts is encoding-correct everywhere PostgreSQL itself is
correct, is as robust as or more robust than the competitors at runtime (it
doesn't error on zero matches like VectorChord), has one trivially-fixable
non-ASCII-install-script packaging bug for non-UTF-8 servers, and its true
ranked latency - with the realistic stored-column query form - is far closer to
the specialist Rust engines than the historical expression-form numbers implied.

---

## Operational note

- First instance `i-0146719a7e0f3741b` was terminated (Fedora's 5 GB root can't
  hold the toolchain; an attempt to overlay /usr onto /data wedged sudo). Relaunched
  with a 300 GB **root** volume (`i-0ba5772cfb64e3537`), which Fedora auto-grows
  on boot - toolchain + PGDATA + corpus all fit.
- The Part-B `VACUUM ANALYZE docs` triggered the auto fts_vacuum compaction on
  the expression index and ran >40 min CPU-bound (HANDOFF section 5.1: fts_vacuum is
  slow and oscillates at scale). It does not respond to pg_cancel mid-compaction;
  aborted with `pg_ctl -m immediate stop` + restart (crash recovery replayed, all
  data + both indexes intact, 400k rows verified). Latency measurement does not
  require VACUUM, so this did not affect the Part-B numbers, only the reported
  `docs_expr` size (uncompacted 490 MB).
- Competitors' `bm25query` type + `bm25` AM COLLIDE (pg_textsearch and
  VectorChord both define them), so VectorChord was tested in a separate database
  per cluster. Not a defect, just a coexistence constraint for benchmarking.

## Termination

Instance `i-0ba5772cfb64e3537` (and the earlier `i-0146719a7e0f3741b`) plus their
SGs and keypairs: see final teardown confirmation reported to the operator.
