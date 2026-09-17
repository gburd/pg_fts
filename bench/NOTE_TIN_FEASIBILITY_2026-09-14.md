# Is TIN pg_fts underneath? And can pg_fts match TIN's claims?

**Date:** 2026-09-14 · **Analysis only — no code changed.**
Companion to `bench/NOTE_VS_TIN_2026-09-14.md` (why a head-to-head benchmark is impossible).

---

## Part 1: Is TIN pg_fts under the covers?

**No.** Five independent lines of evidence, all checkable:

1. **Zero pg_fts fingerprints in TIN's article or docs.** Grepped the full announcement
   plus both doc pages for `ftsdoc`, `ftsquery`, `fts_`, `@@@`, `bm25_`, `to_ftsdoc`,
   `doclen`, `frame-of-reference`, `sparsemap`, `WAND` — **every count zero**. Our entire
   user-visible surface is absent.

2. **The two surfaces are disjoint**, not renamed:

   | | pg_fts | TIN |
   |---|---|---|
   | match operator | `@@@` | `==>` |
   | scoring | `<=>` distance operator | `tin.score(ctid)` |
   | query language | `ftsquery` / `to_ftsquery` | TINQL (its own language) |
   | helpers | `fts_highlight`, `fts_snippet` | `tin.highlight`, `tin.tokenize` |

   A wrapper would not replace the type system *and* the operators *and* the query
   language while leaving no trace of the original.

3. **Different data structures, by their own description.** Two-level bitmaps (256-bit
   page-level + per-page offset bitmaps), AVX-512 intersection, POPCNT counting. We are
   FOR bit-packed delta postings with WAND pruning, entirely scalar. These are not the
   same index with a new name.

4. **Independent authorship and lineage.** Eric Ridge (ZomboDB, pgrx) and Patrick
   Reynolds — a deep Postgres-index background of their own, with no contact with this
   project in its history.

5. **No plausible path.** pg_fts has never been shared with them; it could not appear in a
   managed GA product.

**The convergence is real but explicable:** ctid-as-docid is the obvious answer once you
decide postings must survive a merge without renumbering. Two teams reached it separately.
Our implementation predates the announcement and is visible in our own history.

---

## Part 2: Can pg_fts match TIN's claims? — and a correction to what I told you

I said the bitmap work "needs a `BM25_VERSION` bump and a REINDEX, which our
format-preservation rule treats as a blocker." **The rule is real; that conclusion was
wrong, and our own history disproves it.**

1.5.0 moved per-document length out of the posting lists into a per-segment sidecar —
on-disk format **v3 → v4** — with **no REINDEX**, via a mechanism already in the tree:

- a per-segment **optional pointer** (`doclenstart == InvalidBlockNumber` ⇒ absent),
- **dual-read**: v3 segments keep working and are read the old way
  (`BM25_VERSION_DOCLEN_INLINE 3`),
- new and merged segments get the new structure, so the format **converges as merges run**.

A page-level bitmap can use that identical pattern: add `bitmapstart` to `BM25SegMeta`,
leave it invalid on existing segments, build it for new ones. Old indexes keep working and
gain the acceleration as merges progress. **Adding the structure is not the blocker.**

### What is reachable, ranked by cost

**A. Block-run visibility checking — pure code change, no format change.**
We already do VM-aware counting (`pg_fts_am_scan.c:4399`), but **per TID**:

```c
for (i = 0; i < matches.n; i++) {
    BlockNumber blk = ItemPointerGetBlockNumber(&matches.tids[i]);
    if (VM_ALL_VISIBLE(heap, blk, &vmbuf)) { count++; continue; }
    ...
}
```

`bm25_collect_matches` documents its output as **"sorted, unique"**, and
`docid = block × MaxHeapTuplesPerPage + offset` is monotonic in (block, offset), so **all
matches on one heap page are a contiguous run**. Testing the VM once per run instead of
once per TID is correctness-neutral and bounded by matching tuples per page — TIN notes
pages "often contain 32 or fewer tuples", so up to ~32× fewer VM lookups on a dense count.
This is the same *idea* as TIN's "visibility-map intersection", minus the SIMD.

This is the highest-value-per-risk item on the list and needs no format work at all.

**B. Single-term `count(*)` from `df` — no format change, but narrower than it looks.**
`BM25DictEntry` already stores exact `df`. A single-term count could in principle return
`df` with zero posting reads.

The trap, stated plainly: `df` counts **postings in a segment**, not visible rows. You must
account for tombstones, the pending list, and — the hard one — **MVCC visibility, which
cannot be derived from index metadata at any price**. Note TIN's own framing is conditional:
*"If every heap page is marked all-visible, TIN can return that count without touching a
single heap page."* So this is sound only when the relation is entirely all-visible and the
segment has no tombstones. That is a checkable precondition and a real win on a static
corpus, but it is not the general case, and the article's prose reads more broadly than the
mechanism supports.

**C. Merge without rewriting postings — format-preserving, and we are unusually well placed.**
TIN transfers bitmap ownership between segments rather than recompressing. We cannot
transfer bitmaps we do not have, but the *underlying* win is available: because our docids
are already segment-stable, a merge could **copy a term's posting bytes verbatim** when only
one source segment contains that term and it has no tombstones. In a high-vocabulary corpus
(the field's 98.6M terms) that is the common case for rare and mid-frequency terms.

This is worth more to us than to TIN, because merge write amplification is *exactly* the
open known issue from 1.7.2 — measured at 23–30 pages extended per document.

**D. Two-level bitmaps + SIMD — the real gap, and the real cost.**
This is where TIN's numbers come from, and where we have nothing comparable. The format
side is tractable (see the 1.5.0 precedent). **The actual blocker is that we have no SIMD
infrastructure whatsoever**: no `immintrin.h`, no `__builtin_cpu_supports` dispatch, no
`-mavx2` build plumbing, and a hard requirement to keep working on non-AVX hardware and
non-x86 (ARM) — which means a scalar fallback for every vectorized path, i.e. two
implementations to keep in agreement forever.

It would also cost index size (bitmaps in addition to, or instead of, delta postings) and
touch build, merge, tombstone and scan paths simultaneously — the largest change this
project has attempted, against a competitor we cannot benchmark to verify the payoff.

### Where our own profile says the time actually goes

On the shipped build, a common-term ranked query is **45% doclen path** (28% page load,
17% lookup) and **37% candidate iteration**. That is per-posting scalar work of exactly the
kind a bitmap-and-POPCNT design elides — so the diagnosis is consistent with TIN's design
being genuinely faster on that shape. It also means A and C above do **not** address the
ranked-query gap; they address counting and merge cost.

## Recommendation, if this is picked up

In this order, because it is also increasing risk:

1. **A (block-run VM checking).** Days, no format change, directly comparable to TIN's
   VM-intersection claim, and measurable with the existing `count(*)` harness.
2. **C (verbatim posting copy on merge).** Format-preserving, and it attacks the 1.7.2
   known issue rather than a competitor's press release.
3. **B (df fast-count)** behind its all-visible/no-tombstone precondition, with the
   precondition asserted in a test so it cannot silently return a wrong count.
4. **D (bitmaps + SIMD)** only with explicit sign-off, scoped as a sidecar with dual-read
   per the 1.5.0 pattern, and only after building the SIMD dispatch + scalar-fallback
   infrastructure as its own reviewed change. Not a point release.

**And a standing caveat:** we cannot measure TIN, so "matching TIN" is not a testable goal.
Each of these should be justified by *our own* profile and *our own* field reports — all
four are, independently of TIN — rather than by a number in an article we cannot reproduce.


---

# Outcome (2026-09-17)

A, B and C were planned, implemented where they survived review, and measured. Results in
`bench/RESULTS_ABC_2026-09-17.md`. Corrections to this note:

- **B was already implemented** (`bm25_count_dictdf_fastpath`), with every gate this note
  said it needed. Listing it as work was wrong. It shipped untested, though, so the work
  became ten gate-refusal cases against a heap-only ground truth.
- **A is correct but not measurably faster** — ~1-2%, inside run-to-run noise on repeated
  same-arm runs. This note's "up to ~32x fewer VM lookups" counted CALLS, not TIME:
  `VM_ALL_VISIBLE` on a cached page is nearly free, and the loop is dominated by
  `table_index_fetch_tuple`. Kept as cleanup, not as a performance feature.
- **C was withdrawn.** The merge decodes through `add_posting()` into a build hash table
  that is re-encoded at flush, so there is no byte-stream splice point for a "verbatim
  copy". The claim was a guess about code I had not read closely enough.

**Item D (bitmaps + SIMD) is untouched and remains the only one of the four that could
close the ranked-query gap.** A and B address counting; C does not exist.
