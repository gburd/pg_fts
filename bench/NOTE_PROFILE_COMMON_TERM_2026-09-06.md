# Profiling the common-term ranked gap (2026-09-06)

`perf` on the actual scan, on EC2, at 2.19M docs. Written because ROADMAP 4a
asked for a **format-level trade-off decision** (impact-ordered postings vs our
best-in-field index size) on the strength of a claim I had never measured. The
profile says that claim was wrong, and that the top of the gap was an ordinary
read-path inefficiency.

## Why I profiled instead of asking for the decision

ROADMAP 4a asserted "the cost IS the posting scan". Two arithmetic checks said
otherwise:

- 55.97 ms / 670,976 scored docs = **83 ns/doc ~= 242 cycles** at 2.9 GHz.
  `wand_contrib_cur()` is one FOR-unpack, one doclen lookup, a multiply and a
  divide -- **~10-20 cycles**. A 10-20x hole.
- I had also cited our own `count(*)` = 2.20 ms as "the same posting walk". It is
  not: `bm25_count_dictdf_fastpath()` returns the **dictionary df with no posting
  decode at all** for a single plain term. That comparison was invalid.

## The profile (pg_fts 1.5.9, `year` k10, 56.3 ms steady state)

```
57.02%  wand_contrib_cur
17.16%  bm25_doclen_cursor_load_page
14.45%  bm25_topk_candidates_range
 3.67%  wand_load_block
```

`perf annotate` on `wand_contrib_cur` -- the BM25 math is nearly free (`divsd`
1.68%); the hot instructions are a **binary search**:

```
14.38%  jae   ...          <- loop branch
13.29%  lea   0x1(%rax),%ecx
 6.45%  lea   -0x1(%rax),%edx
 6.42%  cmp   %ecx,%edx
 2.51%  cmp   (%rdi,%rsi,8),%r12
```

~45% of the query was `bm25_doclen_cursor_lookup()`'s binary search, inlined:
**~7 branchy iterations over a 128-entry block, per posting** -- for a term whose
docids are consecutive.

## Fix: ascending-resume hint (SHIPPED HERE)

The WAND scan probes docids in **strictly ascending order**, so the next answer is
almost always the next entry. Try a short linear walk from a resume hint, fall
back to the binary search on a miss. ~8 lines, plus a hint reset in
`load_page()` (a new block must restart the hint).

| query | 1.5.9 | +hint | change |
|---|---|---|---|
| common k10 | 56.30 | **42.67** | **1.32x** |
| common k100 | 69.78 | **54.09** | **1.29x** |
| rare k10 | 5.85 | 5.91 | flat |
| mid k10 | 10.69 | 10.79 | flat |
| 2-term OR | 4.32 | 4.13 | flat |

No format change, no ordering change, no exactness loss. Parity PASS 10/10.

Re-profile after the fix -- `wand_contrib_cur` drops off the list entirely:

```
46.58%  bm25_topk_candidates_range   <- the WAND driver loop is now the top cost
21.33%  bm25_doclen_cursor_load_page
17.80%  bm25_doclen_cursor_lookup
 4.98%  wand_load_block
```

## Instrumented call counts: the rare/mid picture is the opposite of common

Counters on load/lookup/hint-hit, one query each:

| term | df | block loads | lookups | hint hit rate |
|---|---|---|---|---|
| year | 734,896 | 15,220 | 661,888 | **95.5%** |
| slovakia | 10,875 | 5,888 | 10,619 | 31.4% |
| hungary | 24,097 | 11,176 | 24,064 | 25.0% |

- **`year` doclen is now optimal**: 15,220 loads for ~17,094 total sidecar blocks
  = each block decoded about once, 95.5% hint hits. Nothing left to win.
- **rare/mid decode a 128-entry block to serve ~1.8-2.2 lookups** = **71x /
  59x** amplification. A *different* inefficiency from the one 1.5.9 fixed, and
  `perf` on `slovakia` confirms it: **61.13% `bm25_doclen_cursor_load_page`**.

## Attempted fix for rare/mid: lazy per-entry decode -- REJECTED, made it WORSE

Decode entries one at a time with `bm25_for_get()` and stop at the wanted docid;
resume in place for a later probe of the same block (with a private copy of the
packed bytes, since holding a pointer into the page after `UnlockReleaseBuffer`
would be a use-after-unpin bug).

Measured: **rare 5.85 -> 8.72 ms, mid 10.69 -> 14.35 ms.** Reverted.

Why: `bm25_for_get(buf, i)` re-reads the width byte and tests **one bit at a
time** (`width` iterations), whereas batch `bm25_for_unpack()` goes
word-at-a-time and vectorizes. Per entry the random-access path is >10x costlier,
so it loses even at ~2 entries of 128 -- and my version added a `memcpy` of the
packed block per load on top. **The 71x amplification is real but the per-entry
decoder is too slow to exploit it.** A cheap fix would need a *batch* partial
unpack (decode the first N entries word-at-a-time), which is a real change to the
FOR codec -- not attempted here.

## What this means for ROADMAP 4a

The premise was wrong twice over, in the direction that would have cost us the
most:

1. Common-term latency was **not** bounded by the posting scan. 24% of it
   (13.6 ms) was a binary search that an 8-line resume hint removed.
2. The gap is **not** uniformly "scoring O(df) postings". Post-fix, `year`'s
   doclen path is provably optimal, while **rare/mid** carry a 59-71x decode
   amplification -- the band the field actually queries.

Had I brought the size-vs-latency trade-off as written, we might have traded away
the smallest index in the field (1421 MB) to fix a problem whose largest single
component was a read-path bug. **The pruning analysis in
`NOTE_WAND_PRUNING_2026-09-04.md` still stands** (the bound is tight, the
threshold healthy, WAND has nothing to skip on a flat plateau) -- what it did not
establish, and what I wrongly asserted on top of it, is that the *remaining time*
was irreducible posting-scan cost.

Standing gap after this fix: common k10 **42.67 ms** vs pg_search 2.12 /
vchord 3.49 / pg_textsearch 20.71. Still the worst number, and the WAND ceiling
is still real -- but the next lever to try is a **batch partial FOR unpack** for
the rare/mid amplification, which costs no format change and no exactness, not an
impact-ordered posting layout.
