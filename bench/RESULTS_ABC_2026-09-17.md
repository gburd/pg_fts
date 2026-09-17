# A / B / C: results

**Date:** 2026-09-17 · Host: r6id.4xlarge, PG 17.10, local NVMe
**Raw:** `bench/data_abc_2026-09-17/`
**Plan:** `bench/PLAN_ABC_2026-09-14.md`

Three items were proposed in the TIN feasibility note. Reading the code moved all three, and
measuring moved one further.

---

## B — was already implemented. Scope became testing.

`bm25_count_dictdf_fastpath()` already counts a single plain term from `Sum(df)` with no
posting decode and no heap probe, behind all four gates the feasibility note said were
needed (one plain positive term; no pending docs; no tombstones; whole heap all-visible),
plus a generation re-check against concurrent merge.

**My feasibility note was wrong to list B as work.** The real gap was coverage: one positive
case (`big_fastpath`) and *nothing* proving the gates refuse. For a counting path that is
the dangerous shape — a missed gate returns a plausible wrong number.

**Ten gate cases added** to `sql/pg_fts.sql`, each comparing the index count against a
ground truth computed with `enable_seqscan=on` / indexscan+bitmapscan off, so a broken gate
shows as a mismatch rather than an unquestioned number:

| case | count | behaviour |
|---|---|---|
| `plain-term-fastpath` | 60 | fast path taken |
| `rare-single-term-fastpath` | 1 | fast path, rare term |
| `prefix-falls-back` | 60 | refuses |
| `conjunction-falls-back` | 1 | refuses |
| `disjunction-falls-back` | 60 | refuses |
| `negation-falls-back` | 59 | refuses |
| `pending-falls-back` | 65 | refuses |
| `tombstones-fall-back` | 60 | refuses |
| `not-all-visible-falls-back` | 63 | refuses |
| `fastpath-again-after-vacuum` | 63 | fast path returns |

**One test-design fix worth recording:** the first version of these probes used terms the
corpus did not contain, so three cases compared `0` against `0` — passing while proving
nothing. They now use terms that genuinely exist (`bigterm` in every doc, `t1d7` in exactly
one), so every case asserts a non-zero count.

---

## A — implemented, correct, and **not measurably faster**. Kept anyway, but not as a perf claim.

`bm25_count_visible()` did two things per TID that only needed doing per block run:
`VM_ALL_VISIBLE()` on the same heap page once per matching tuple, and
`table_slot_create()` + `ExecDropSingleTupleTableSlot()` per probed TID.

The premise checks out: `tidset_sort_uniq()` sorts with `cmp_tid` and de-duplicates, and
`docid = block × MaxHeapTuplesPerPage + offset` is monotonic in (block, offset), so matches
on one page are a strictly contiguous run. The VM is page-granular, so the answer cannot
differ between two TIDs on a page within a scan.

### Correctness: identical counts in both arms

2,000,000 (dense) and 300,000 (sparse), byte-identical between base and fix, on both the
all-visible and dirtied-heap paths. This was asserted before looking at any timing.

### Speed: no.

Corpora were deliberately shaped to favour the change — dense at **136 tuples/page**,
sparse at **6.3**:

| workload | base | fix |
|---|---|---|
| all-visible dense (2M rows) | 0.109 ms | 0.110 ms |
| all-visible sparse (300k) | 0.237 ms | 0.241 ms |
| dirtied dense | 436.8 ms | 399.9 ms |
| dirtied sparse | 111.5 ms | 110.0 ms |

The dirtied-dense line looked like an 8.5% win. **It was noise.** Re-running the same arm
three times, twice:

```
base medians: 408.2 401.6 407.6   |  and: 400.3 397.3 402.7
fix  medians: 399.3 402.7 398.8   |  and: 397.5 397.4 399.0
```

The ranges **overlap** (base low 401.6 < fix high 402.7). The apparent 8.5% came from a
single base run at 436.8 ms — higher than all six medians measured afterwards. The real
effect is **~1–2%, indistinguishable from run-to-run variation**.

Two reasons, both of which correct my own note:

- **The all-visible rows show nothing because they never enter this loop.** 0.11 ms for a
  2M-row count is the *df fast path* (B) answering it. That arm was measuring B.
- **"Up to 32× fewer VM lookups" counted CALLS, not TIME.** `VM_ALL_VISIBLE` on a pinned,
  cached VM page is nearly free; the loop's cost is `table_index_fetch_tuple` heap probes,
  which this change does not touch. I projected a speedup from a call-count ratio without
  checking what fraction of the time those calls were.

**Kept** because it is strictly less work for identical output, removes a per-TID
allocation, and is now covered by the count tests — but it ships as a code-quality change
with a measured "no significant effect", not as a performance feature.

---

## C — withdrawn. The premise did not survive reading the code.

The note claimed a merge could "copy a term's posting bytes verbatim" when a single source
segment holds the term untombstoned. `bm25_merge_segments_streaming()` decodes each source
term via `bm25_decode_term()` and feeds every posting through `add_posting()` into a build
hash table that is re-encoded at segment flush. **There is no byte-stream splice point** —
the output framing is produced by the builder, and the per-posting path also feeds the
doclen sidecar and re-quantizes doclen from v4 sources.

A verbatim copy would have to bypass all of that and reproduce the builder's exact output
format, in the one code path that has already produced a P0 (non-terminating VACUUM) and two
crash fixes on this release line. **C was a guess about code I had not read closely enough.**
Not attempted.

---

## Net

- **B:** real feature, already shipped, now genuinely tested (10 cases, non-vacuous).
- **A:** correct, no measurable speedup, kept as cleanup with the measurement recorded.
- **C:** withdrawn with the reason.

The recurring lesson, now with a fourth instance: a projected ratio (32× fewer calls) is not
a measurement, and single-run comparisons on a shared host manufacture wins. Both were
caught here only because correctness was asserted first and the arm was re-run against
itself.
