# Design: a doclen sidecar for pg_fts (per-DOC length, stored once)

Read-only research + design. Nothing edited. Cites current code at
`pg_fts_am.h` / `pg_fts_for.h` / `pg_fts_am.c` / `pg_fts_am_scan.c`, the P1
regression notes (`bench/RESULTS_P1_P4.md`, `bench/NOTE_SIZE_SPEED_REPLAN.md`),
and `RELEASING.md`.

TL;DR: everyone but pg_fts stores document length **once per document**, and
Lucene/Tantivy quantize it to **one byte** (a "fieldnorm"). pg_fts stores it
once per **posting** (per doc x term), the widest FOR column — the model in
`NOTE_SIZE_SPEED_REPLAN.md` §1a puts it at ~56% of a dense block, ~35-45% of the
index. The P1 sidecar attempt did not fail because the *concept* is wrong; it
failed because (a) `fts_vacuum` couldn't reclaim the new format (a bug since
fixed in 1.2.2), and (b) it was measured stacked with three other changes and a
1 GB build overflow, never in isolation. A correct sidecar is a strictly smaller
structure (1 byte/doc, or ~2 bytes exact, vs the doclen FOR column duplicated T
times) and adds ~zero scoring latency because the array is tiny (~2 MB per 2.19M
docs) and stays resident.

---

## PART 1 — how competitors store doclen (the 1-byte fieldnorm is the headline)

### Lucene / Tantivy (ParadeDB pg_search embeds Tantivy)

Lucene does NOT store document length in the postings. It stores a per-field,
per-document **norm** ("fieldnorm") in a separate `.nvd`/`.nvm` structure: one
value **per document per indexed field**, addressed by the dense internal docid
(0..maxDoc). For a BM25 field the stored norm IS the document length (number of
terms in that field for that doc), lossily quantized to a **single byte**.

The quantization is `SmallFloat.intToByte4` / `byte4ToInt` — a mini
floating-point code in one unsigned byte: a 3-bit mantissa and a 5-bit exponent
(with a bias so small lengths keep more resolution). Encoding maps an integer
length L to one byte; decoding recovers an approximate length L'. The mapping is
monotonic and exact for small L and increasingly coarse for large L, which is
exactly right for BM25: length only enters through the normalization
denominator, so a few-percent error on a 40 000-token doc is invisible in the
final score ordering. Lucene precomputes, per field, a 256-entry table
`float[] cache` mapping each possible norm byte to its BM25 length-norm factor
`(1 - b) + b * decodedLen / avgFieldLength`, so scoring a posting is a single
array index on the norm byte — no divide, no decode.

BM25 in Lucene (`BM25Similarity`): `score = idf * tf' * (k1 + 1) /
(tf' + norm)` where `tf'` is the term frequency and `norm = k1 * cache[normByte]`
with `cache[b] = (1 - b_param) + b_param * decodeLength(b) / avgdl`. The point:
**the length term is a byte lookup**, not a per-posting integer.

Tantivy (what ParadeDB pg_search runs inside Postgres) mirrors this: fieldnorms
are a separate per-document column (`FieldNormReader`), one quantized byte per
doc per field, encoded with the same 3-bit-mantissa/5-bit-exponent `id_to_fieldnorm`
table. BM25 scoring reads the byte, decodes via a 256-entry table, done.

So the two most-deployed BM25 engines both: (1) store doclen once per doc, not
per posting; (2) lossily quantize it to one byte; (3) turn scoring's
length-normalization into a table lookup on that byte.

### VectorChord-bm25

tsvector-derived BM25. It keeps a per-document length so it can compute avgdl and
the per-doc normalization; the length lives in a per-document structure keyed by
the document's row identity, not replicated into every posting. (VChord's index
in `RESULTS_VS_VCHORD_PGTEXTSEARCH.md:25` is 1367 MB vs pg_fts's 7541 MB — a
big part of that gap is that pg_fts pays doclen per posting and also stores
positions, per `:27,:69`.) Exact byte-encoding is an implementation detail, but
the structural fact holds: doclen is per-doc, stored once.

### Timescale pg_textsearch (native-C BM25)

Also stores per-document length once (a doc-length side column / per-doc metadata
consulted at scoring time for the avgdl normalization), not per posting.
`RESULTS_VS_VCHORD_PGTEXTSEARCH.md:26` puts it at 1831 MB — again, no
per-posting length duplication.

### The framing (confirmed)

**Nobody stores doclen per posting. It is a per-document quantity, stored once,
and the dominant engines compress it to a single quantized byte.** pg_fts is the
outlier: `BM25Posting` carries `doclen` (`pg_fts_am.h:118-123`) and the write
path packs a doclen for every posting in every block
(`pg_fts_am.c:1321` gathers `sorted[i].doclen`, `:1359` packs the `dls[]`
column). A doc with T distinct terms writes its length T times.

---

## PART 2 — did P1 fail because of the concept, or the (now-fixed) vacuum bug?

`RESULTS_P1_P4.md` reports P1 (format v3/v4 doclen sidecar) grew the index:
14.7 GB -> 16.2 GB after build; the compacted comparison was **4139 MB (v2,
one fts_vacuum pass) vs 15 GB (v4, fts_vacuum reclaimed nothing)**. Three causes,
from `NOTE_SIZE_SPEED_REPLAN.md` §2, re-weighted against what is now fixed:

1. **fts_vacuum stopped reclaiming (dominant, and now a red herring).** The
   headline "15 GB vs 4.1 GB" is mostly *un-compacted v4 vs compacted v2*. On v4,
   `fts_vacuum` ran 1992 s and left the file byte-for-byte unchanged
   (`RESULTS_P1_P4.md` §Index). Since then, **1.2.2 fixed the reclaim path**: the
   recycle gate + `fts_vacuum` now taking `AccessExclusiveLock` (see the recycle
   gate at `pg_fts_am.c:2391-2459` and `fts_vacuum` at `pg_fts_am.c:4766-4790`,
   which `index_open(..., AccessExclusiveLock)` and calls `bm25_vacuum_compact`).
   **A format change that fts_vacuum can't reclaim is an automatic size
   regression independent of the format's own efficiency** — and that specific
   failure mode is no longer present. This alone means the "P1 made it bigger"
   result does not indict the sidecar concept.

2. **P1 shipped side-structures that added bytes (an impact-tier directory) while
   NOT dropping enough posting bytes to offset them.** P1 was not a clean "drop
   doclen from postings, add 1 byte/doc"; it stacked a doclen sidecar AND a P4
   impact-tier directory. The impact tiers are separately blamed for the latency
   blowups. The sidecar's own size delta was never isolated.

3. **The build didn't even run at scale.** Committed P1 HEAD failed
   `CREATE INDEX` at 2.19M with `invalid memory alloc request size 1073741824` —
   `bm25_write_doclens()` gathered every posting-pair of the whole segment into
   one flat array that crossed `MaxAllocSize`. All P1 numbers are from a
   one-line-patched build. So the "measured" P1 is a patched, stacked, un-reclaimed
   artifact.

**Re-assessment:** P1 failed on **execution and measurement**, not concept. It
(a) rode a since-fixed vacuum-reclaim bug that dominated the size number, (b) was
never measured in isolation from the impact-tier directory and the P4 traversal
changes, and (c) didn't build at scale. The one *conceptual* risk
`NOTE_SIZE_SPEED_REPLAN.md` §2 raises that survives is real and must be designed
around: **a docid-ordered sidecar can re-inherit FOR's block-max widening** — a
single 50 000-token doc in a docid-adjacent run widens its sidecar block just as
it widened the in-block column. The fix for that (below) is to **quantize to a
fixed 1 byte/doc**, which has no block-max widening at all.

---

## PART 3 — concrete sidecar design for pg_fts

### Current on-disk facts this design builds on

- **docid is a GLOBAL SPARSE 48-bit value**, not a dense per-segment ordinal:
  `bm25_tid_to_docid` = `blocknum * MaxHeapTuplesPerPage + offset`
  (`pg_fts_am.c:643-650`). This is the single most important fact for indexing
  the sidecar (see below) — you cannot index by "docid ordinal 0..ndocs" because
  docids are sparse over the heap's block space.
- A posting block is `BM25BlockHdr` (28 bytes, 7x uint32, `pg_fts_am.h:161-172`)
  + three FOR columns docid-gaps|tf|doclen (`pg_fts_am.c:1357-1359`), optional
  4th positions column.
- Scoring reads doclen **lazily, in-block**: `wand_contrib_cur`
  (`pg_fts_am_scan.c:2879-2886`) does `dl = bm25_for_get(c->blkbuf + c->dloff,
  c->cur)` — a random-access FOR extract from the block copy already in
  `c->blkbuf`. Block-max WAND also needs `bh->min_doclen` (`pg_fts_am.h:164`,
  used in `wand_block_maxscore` at `pg_fts_am_scan.c:2808`) to bound a whole
  block's best score.
- `BM25SegMeta` (`pg_fts_am.h:59-80`) is the per-segment descriptor:
  `dictstart / trgmstart / livedocs / ndocs / sumdoclen / nterms / ndeleted /
  livedocslen / dictindexstart`. Adding a field here is a format change per
  `RELEASING.md` ("What counts as a format change: ... the segment descriptor
  (`BM25SegMeta`)").
- The metapage carries `magic / version / ...` and `version == BM25_VERSION`
  (currently 3, `pg_fts_am.h:24`) is enforced by `bm25_check_meta`
  (`pg_fts_am.c:1221-1227`).

### 1. Storage layout

**A per-segment doclen sidecar: a page chain, referenced by a new
`BM25SegMeta.doclenstart` field, storing one quantized length byte per document
in the segment, ordered by segment-local docid, PLUS a small offset directory so
a docid maps to its byte in O(log) without scanning.**

Because docids are **sparse** (global TID-derived, `pg_fts_am.c:643-650`), the
sidecar is NOT a flat `array[ordinal]`. Two workable layouts:

- **(A) Sorted (docid, normbyte) — recommended.** For each doc in the segment,
  store its docid delta-coded + FOR-packed (reuse `pg_fts_for.h`, same codec as
  everything else) and its 1 quantized length byte, in ascending docid order,
  chunked into 128-doc blocks like postings. A tiny per-block first-docid header
  lets a lookup binary-search to the block, then linear-scan 128 entries. This
  mirrors the existing dict sparse-block-index pattern (`BM25DictIndexEntry`,
  `pg_fts_am.h:127-133`) and the posting block structure — reuse, not new
  machinery. Size: ~1 byte norm + ~1 byte docid-gap amortized ≈ **~2 bytes/doc**.

- **(B) Store the sidecar sorted the SAME way the segment already enumerates its
  docs.** The segment's postings for the *most-common* term, or a build-time doc
  enumeration, already fixes a docid order. If the build already has, per doc, a
  `(docid, doclen)` pair (it does — `bm25_write_postings` sees every posting), a
  single dedup-by-docid pass at flush/merge produces the sorted sidecar directly.
  This is the same data P1 gathered, but capped: dedup **during** gather (a hash
  or a merge over already-docid-sorted per-term runs), never a 400M-pair flat
  array — that was the P1 build OOM (`RESULTS_P1_P4.md` §Build failure).

Either way the sidecar lives on its own `BM25_DOCLEN` page chain (a new opaque
flag alongside `BM25_LIVEDOCS` etc., `pg_fts_am.h:29-40`), first page recorded in
the new `BM25SegMeta.doclenstart`. Old segments have `doclenstart =
InvalidBlockNumber` and keep inline doclen; new segments set it and drop the
doclen FOR column from postings.

**Lookup at scoring time.** The WAND cursor (`WandCursor`,
`pg_fts_am_scan.c:2582-2611`) already knows its `segidx` (`:2607`). Add to the
cursor a pointer to that segment's decoded doclen sidecar (loaded once when the
cursor's segment is opened, exactly like tombstones are loaded once into
`BM25Tombstones` at `pg_fts_am_scan.c:180-194`). Then `wand_contrib_cur` replaces
`dl = bm25_for_get(c->blkbuf + c->dloff, c->cur)` with `dl =
doclen_lookup(c->doclens, c->docid)` — a binary search into the resident sidecar
(layout A) or, if the sidecar is decoded into a hash/sorted array at open, an
O(1)/O(log) probe. Block-max WAND's `bh->min_doclen` stays in the block header
(it is one uint32 per 128-block, negligible, and pruning must not pay a sidecar
lookup) — keep it; it is not the size problem.

### 2. Scoring lookup cost / latency risk

Today doclen is inline in `c->blkbuf` — a sequential, cache-hot FOR extract. A
sidecar is a random-ish lookup per scored posting. Assess:

- **Size resident:** 1 byte/doc x ndocs. For 2.19M docs that is **~2.2 MB** for
  the whole corpus's norms (or ~4.4 MB with docid keys in layout A). Per segment
  it is smaller. This trivially fits L2/L3 + `shared_buffers`; once the cursor
  decodes it at segment-open (or the pages are pinned), every lookup hits RAM.
  **No re-read per posting.**
- **Only SCORED postings pay.** `NOTE_SIZE_SPEED_REPLAN.md` §0 established doclen
  decode is already lazy — pruned blocks never touch it. The sidecar preserves
  this: `wand_contrib_cur` is called only on scored candidates
  (`pg_fts_am_scan.c:3306,3456,3467`). A binary search over ~ndocs entries is
  ~21 comparisons worst case on a resident 2 MB array — sub-microsecond, and far
  fewer if the cursor decodes the sidecar into a docid->norm structure once.
- **Verdict:** no latency regression, and it removes ~56% of the bytes memcpy'd
  per loaded block (`memcpy(c->blkbuf, stream, bh->bytelen)`,
  `pg_fts_am_scan.c` block-load, since `bytelen` drops the doclen column) — a
  small *latency win* on common terms, not a loss. The one requirement: **decode
  the sidecar once per (segment, scan), not per posting.** Load it beside the
  tombstones (`bm25_read_tombstones`-style, `pg_fts_am_scan.c:180`).

### 3. Format-change plumbing (per RELEASING.md — MANDATORY)

`RELEASING.md` "On-disk format changes": adding `BM25SegMeta.doclenstart` and
dropping the doclen posting column is a format change (touches `BM25SegMeta` and
the FOR posting encoding). Required work, all of it:

1. **Bump `BM25_VERSION`** 3 -> 4 (`pg_fts_am.h:24`); `bm25_check_meta`
   (`pg_fts_am.c:1221`) currently *errors* on a version mismatch — change it to
   *accept* both 3 and 4 (dual-read), erroring only below the oldest supported.
2. **Dual-read.** A segment is old-format iff `seg->doclenstart ==
   InvalidBlockNumber`. Old segment: postings still carry the doclen FOR column;
   `wand_contrib_cur` reads it in-block as today (keep the `dloff`/`bm25_for_get`
   path). New segment: postings omit the doclen column, `wand_contrib_cur` reads
   the sidecar. The decode path (`pg_fts_am.c:919-956`) must key off the same
   per-segment flag: for old segments unpack three columns; for new, unpack two
   (gaps, tf) and pull doclen from the sidecar. The block header's `bytelen`
   naturally differs, so the column-skip arithmetic (`p = (bh+1) + bh->bytelen +
   bh->posbytelen`, `pg_fts_am.c:960`) needs no change beyond the writer emitting
   the shorter `bytelen`.
3. **Lazy in-place migration.** `bm25_merge_segments` and `fts_vacuum`'s
   `bm25_vacuum_compact` already rewrite segments; the rewrite writes the NEW
   format (sidecar + doclen-less postings). An old-format index converges to new
   as merges/vacuum run — no REINDEX, no second full copy. This is exactly the
   `RELEASING.md` §3 "migrate lazily and in place" contract. The recycle gate
   (fixed 1.2.2, `pg_fts_am.c:2391-2459`) makes this reclaim correctly — the P1
   blocker.
4. **A no-op `pg_fts--1.2.2--1.3.0.sql`** (SQL objects unchanged; the C code does
   the byte migration) + a **TAP upgrade test**: build an index on the prior
   release, `ALTER EXTENSION pg_fts UPDATE`, load the new `.so`, assert queries
   return correct scores against the old-format segment, then `fts_merge()` /
   `VACUUM` and assert the segment migrated (new `doclenstart` set) and results
   still match. Gate it, per `RELEASING.md` §5.
5. **Minor release `1.3.0`**, CHANGELOG stating: doclen moved to a per-segment
   sidecar, existing indexes keep working without REINDEX, merge/vacuum completes
   the migration.

### 4. Why this avoids the P1 failure

- **Unambiguously smaller.** 1 byte/doc (or ~2 with docid keys) replaces the
  doclen FOR column, which is ~2.0 bytes/posting and duplicated T times per doc
  (`NOTE_SIZE_SPEED_REPLAN.md` §1a: ~56% of a dense block). For Wikipedia's
  high-T docs this is a large net drop. There is no impact-tier directory riding
  along (that was P4, separately reverted).
- **Vacuum reclaims it.** The reclaim bug that dominated P1's size number is
  fixed in 1.2.2 (`pg_fts_am.c:2391-2459`, `fts_vacuum` @ AEL). The migration
  reuses the merge/vacuum rewrite that now converges and truncates.
- **No block-max widening pathology.** A fixed 1-byte quantized norm has no width
  to widen — the exact failure mode `NOTE_SIZE_SPEED_REPLAN.md` §2 warned a
  docid-ordered sidecar could re-inherit is designed out by quantization.
- **Built EXTEND-ONLY, dedup-during-gather.** No 400M-pair flat array
  (`RESULTS_P1_P4.md` §Build failure). Dedup by docid as postings are gathered,
  emit the sidecar in one streaming pass, huge-safe allocs like the rest of the
  build.
- **Measured in isolation.** Ship ONLY the sidecar (no other change), measure
  build size before/after `fts_vacuum` at 2M, confirm the drop, confirm ranked
  latency within noise, confirm the ground-truth ranked-parity test
  (`NOTE_SIZE_SPEED_REPLAN.md` §4) is unchanged.

### Recommendation: lossy 1-byte norm vs exact doclen

**Use the lossy 1-byte SmallFloat-style norm (Lucene/Tantivy), gated behind a
correctness check; keep exact `sumdoclen` in `BM25SegMeta` for avgdl.**

- Exact per-doc doclen (uint16 or FOR-packed) is ~2 bytes/doc and adds no scoring
  error, but it re-exposes the block-max-widening risk (a docid-adjacent
  50 000-token doc widens its FOR block) and is 2x the size of the 1-byte norm.
- The 1-byte norm is half the size, immune to widening, and turns scoring's
  length term into a byte -> factor table lookup (Lucene's 256-entry cache) —
  precompute `cache[b] = k1_1mb + k1b_inv_avgdl * decode(b)` per cursor and
  `wand_contrib_cur`'s `norm` becomes `tf + cache[normByte]`, one array index, no
  multiply. avgdl is unaffected: it comes from the **exact** `sumdoclen`/`ndocs`
  already in `BM25MetaPageData` (`pg_fts_am_scan.c:3663`) and `BM25SegMeta`
  (`pg_fts_am.h:64`) — those stay exact; only the per-doc normalization
  denominator is quantized, which is what Lucene does.
- **Correctness gate (mandatory, do NOT skip):** BM25 ordering must survive
  quantization. The existing pre-existing WAND inexactness bug
  (`RESULTS_P1_P4.md` §Correctness — both v0.2.0 and HEAD drop true top-k)
  means you must pin a **ground-truth exact top-k parity test FIRST**
  (`NOTE_SIZE_SPEED_REPLAN.md` §4), then confirm quantized scoring changes it by
  at most a bounded, documented amount (Lucene accepts this; pg_fts should state
  it). If exactness is a hard product requirement, fall back to exact uint16 —
  it's still a big size win over per-posting duplication, just without the
  block-widening immunity, and keep it as the conservative default with the
  1-byte norm behind a reloption.

Recommended default: **1-byte norm** (matches the engines pg_fts is measured
against, halves the sidecar, kills the widening risk), exact uint16 as the
fallback if the parity test demands it.

### Estimated size saving

Per `NOTE_SIZE_SPEED_REPLAN.md` §1a, the doclen FOR column is ~2.01 B/posting,
~56% of a dense block, and the note models doclen as ~35-45% of total index size.
Replacing "~2 B x (postings) = ~2 B x sum_over_docs(T)" with "1 B x ndocs" saves
roughly `2*sum(T) - 1*ndocs` bytes = `ndocs * (2*avg_T - 1)`. For Wikipedia
articles avg_T is in the hundreds, so the doclen bytes drop by well over 99% of
their current footprint. Net index effect: **the ~35-45% that is doclen collapses
to a rounding error**, i.e. a realistic **~30-40% smaller index** once vacuum
reclaims — matching P1's original (correct) prediction, which P1's execution
never delivered. **This is a MODEL; confirm with the §4 isolation measurement at
2M before believing it.**

### Latency risk

Low. Sidecar is ~2 MB resident, decoded once per (segment, scan), looked up only
for scored postings (already lazy), and it *removes* ~56% of per-block memcpy on
common terms. The one thing that would reintroduce a regression — a per-posting
page read of the sidecar — is avoided by loading it once beside the tombstones
(`pg_fts_am_scan.c:180-194`). Gate with the same kill criteria as
`NOTE_SIZE_SPEED_REPLAN.md` §4: revert if any ranked query regresses >3% or the
ground-truth parity test changes beyond the documented quantization bound.

---

## Exact code touch-points (summary)

| Change | Location |
|---|---|
| New opaque flag `BM25_DOCLEN` | `pg_fts_am.h:29-40` (next bit after `BM25_DICTINDEX`) |
| New field `BlockNumber doclenstart` in `BM25SegMeta` | `pg_fts_am.h:59-80` |
| Bump `BM25_VERSION` 3->4 | `pg_fts_am.h:24` |
| Accept versions {3,4} instead of erroring | `bm25_check_meta`, `pg_fts_am.c:1221-1227` |
| Drop doclen from `dls[]` packing on new segments; write sidecar chain | write path `pg_fts_am.c:1319-1360` (dedup-during-gather, extend-only) |
| Dual-read decode: 3 columns (old) vs 2 + sidecar (new) | `pg_fts_am.c:919-960` |
| Add `doclens` sidecar ptr + `normByte->factor` cache to cursor | `WandCursor`, `pg_fts_am_scan.c:2582-2611` |
| Load sidecar once per segment (like tombstones) | beside `bm25_read_tombstones`, `pg_fts_am_scan.c:180-194`; cursor setup `pg_fts_am_scan.c:3790-3806` |
| Sidecar lookup replaces in-block doclen extract | `wand_contrib_cur`, `pg_fts_am_scan.c:2879-2886` |
| Keep `bh->min_doclen` block-max bound as-is | `pg_fts_am.h:164`, `wand_block_maxscore` `pg_fts_am_scan.c:2808` |
| Migration on rewrite (writes new format) | `bm25_merge_segments` / `bm25_vacuum_compact` `pg_fts_am.c:2617-3030,3219+` |
| No-op SQL + TAP upgrade test | `pg_fts--1.2.2--1.3.0.sql`, `t/` |
| SmallFloat-style quantize/decode + 256-entry factor cache | new small static in `pg_fts_for.h` (pure C, testable) or `pg_fts_am_scan.c` |

Reuse, don't reinvent: the sidecar block layout reuses `pg_fts_for.h` and the
`BM25DictIndexEntry` sparse-index pattern; the per-segment load reuses the
tombstone loader; the migration reuses the merge/vacuum rewrite. The only new
code is the quantization table and the docid->byte lookup.
