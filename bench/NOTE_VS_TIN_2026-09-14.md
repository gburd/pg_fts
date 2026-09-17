# pg_fts vs TIN (PlanetScale) — comparison, and why the benchmark could not be run

**Date:** 2026-09-14
**Source:** <https://planetscale.com/blog/introducing-tin> (Eric Ridge, Patrick Reynolds,
2026-09-16), plus `planetscale.com/docs/postgres/search{,/get-started}` and
`github.com/planetscale/paradedb-benchmarker`, all read in full.

## Verdict on benchmarking: NOT POSSIBLE, and not for a technical reason

I could not benchmark TIN, and no amount of EC2 budget changes that. Checked, each
returning what is recorded here:

| what I looked for | result |
|---|---|
| `github.com/planetscale/tin` | **404** |
| TIN in any GitHub search | **0 repositories** |
| Source tarball / PGXN / apt / yum package | none referenced anywhere in the docs |
| A TIN driver in PlanetScale's own public benchmarker fork | **absent** — the fork has backends for paradedb, postgres, elasticsearch, opensearch, clickhouse, mongodb; no `tin` |
| Install instructions | `CREATE EXTENSION tin`, and on failure: *"your cluster needs an update… go to the **Clusters** page for your branch"* |

TIN is a **closed, managed-service-only extension**. Their own capability table lists
"Available on PlanetScale" as the first row, with ✅ for TIN and ❌ for ParadeDB
`pg_search` and `pg_textsearch` — i.e. availability on their platform is presented as a
feature, which it is, but it also means the binary exists nowhere else.

So the article's claim that *"anyone who wants to reproduce our benchmarks of competing
text-search indexes can do so using the same instance type and container limits"* is
precisely worded: you can reproduce their measurements of **the competitors**. You cannot
measure TIN unless you are a PlanetScale customer, and even then not against a local build
on an instance you control. **I am not going to spend EC2 hours producing a pg_fts column
to sit beside numbers I cannot reproduce, verify, or contest.** That would be exactly the
one-sided comparison this project's benchmark discipline exists to prevent — and I have
already been burned this session by trusting a number I could not re-derive.

## The architectural comparison, which IS possible

Read against our own source, the most interesting finding is agreement, not difference.

### TIN's central claim does not apply to pg_fts

The article's thesis is that using `ctid` as the posting identifier avoids the
renumbering and write amplification that afflicts engines with per-segment sequential
document IDs:

> *"Text indexing systems that use sequential document identifiers are required to renumber
> all documents when they create a new, merged segment… the entirety of each segment's data
> gets repacked, recompressed, and rewritten. While it's not quite 2× the storage to merge
> two segments, it can be close."*

**pg_fts already does the ctid thing** (`pg_fts_am.c:724`):

```c
#define BM25_OFFSET_FACTOR ((uint64) MaxHeapTuplesPerPage)
static inline uint64
bm25_tid_to_docid(ItemPointer tid)
{
	return (uint64) ItemPointerGetBlockNumber(tid) * BM25_OFFSET_FACTOR +
		(uint64) ItemPointerGetOffsetNumber(tid);
}
```

A pg_fts docid is a pure function of the heap TID, globally stable, identical in every
segment. There is no renumbering on merge here either. So that critique lands on
Lucene/Tantivy-derived designs (ParadeDB), not on us — we reached the same conclusion
independently, and it is *also* why our own docid space is sparse, which is the thing that
made the 1.6.1 tombstone bug subtle.

Shared with TIN: ctid-derived identifiers, immutable segments with background merging, a
per-segment liveness/tombstone structure (theirs a bitmap, ours a sparsemap), BM25 top-k,
exact `COUNT(*)`, phrase/proximity, fuzzy/wildcard/regex, and MVCC-correct results via
custom scans.

### Where TIN is genuinely different, and probably genuinely faster

Two-level bitmaps — a 256-bit page-level bitmap per term plus small per-page offset
bitmaps — sized so that a page bitmap fits one AVX2 register and an offset bitmap fits one
AVX-512 register. That buys them:

- **Work elision:** intersect page-level bitmaps first; any page absent from the result
  needs no offset decoding at all.
- **Counting without reading postings:** term metadata carries exact posting counts, so if
  two terms' page bitmaps are disjoint, the disjunction count is just the sum.
- **SIMD + POPCNT** for intersect/union/count instead of scalar loops.
- **Visibility-map intersection:** the VM is itself a page-level bitmap, so only
  not-all-visible pages need heap checks.
- **Merge without recompression:** bitmaps can be transferred between segments by
  ownership rather than rewritten.

pg_fts instead stores FOR bit-packed delta-encoded postings and prunes with WAND, entirely
scalar. That is a real architectural gap, and it is the same gap my own profiling keeps
pointing at: on the shipped build a common-term ranked query spends **45% of its time in
the doclen path** and 37% in candidate iteration — per-posting scalar work that a
bitmap-and-POPCNT design largely does not do.

Their reported absolute numbers (199 QPS mixed top-10 on 150M documents, 10,260 QPS for
counting on an in-memory Wikipedia) are plausible for that design. I have no way to check
them and am not treating them as established.

### One claim I can partly check, and it is fair

They report `pg_textsearch` "handles only disjunction searches" and cannot do `COUNT(*)`.
That matches what I measured independently in the C1 cross-engine work: `pg_textsearch`
and vchord could not run our `count(*)` form at all, and pg_fts beat pg_search on it by
**5.7×** (2,923 vs 513 tps). So on the one axis where our measurements overlap, their
characterisation of a competitor agrees with mine.

## What this means for pg_fts, concretely

1. **The ctid-docid design is vindicated.** The strongest architectural argument in the
   article is one pg_fts already implements. Worth saying in our own docs, since the piece
   frames it as unique to TIN.
2. **The SIMD-bitmap gap is the real one**, and it is not a micro-optimisation — it is a
   posting-format change (bitmaps instead of delta-packed postings). ROADMAP item 4a
   (common-term ranked) is the near-term slice of this, but the full version is a format
   redesign that would need a `BM25_VERSION` bump and a REINDEX, which is a blocker under
   our format-preservation rule.
3. **Positioning is unchanged for our users.** TIN is unavailable off PlanetScale, so for
   anyone self-hosting, on RDS, on Aurora, or on any other managed Postgres, it is not an
   option and pg_fts is not competing with it. Where it matters is as a design target.
4. **`doc/COMPARISON_MATRIX.md` gets a TIN row marked "managed-service only, unmeasured"** —
   never "No", and never with numbers copied from their article as if we had reproduced
   them.

## What I would need to make this a real benchmark

A TIN build installable on an EC2 instance I control (source, or a binary for PG 17/18).
If PlanetScale publishes one, the comparison is straightforward: their corpus (Stack
Exchange Q&A export, 85 GB / 150M docs) and harness are both public, and the pg_fts arm
would slot into the existing `bench/` scripts. Failing that, a second-best option is to run
the *published* competitor set (ParadeDB, GIN, pg_textsearch) plus pg_fts on their exact
instance type and container limits, which at least places pg_fts on the same axis as their
table without asserting anything about TIN. That is a real, useful run — I have not done it
here because it was not what was asked, and it costs several hours of EC2 time.
