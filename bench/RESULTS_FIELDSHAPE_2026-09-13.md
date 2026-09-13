# Field-shape investigation: the ~2.87M-doc email-body index

**Date:** 2026-09-13
**Host:** r6id.8xlarge (32 vCPU / 247 GB / 1.7 TB NVMe), PG 17.10, local NVMe
**Raw:** `bench/data_fieldshape_2026-09-13/`

## First: who the 2.87M shape belongs to

The 1.6.1 letter carrying this shape was **misaddressed**. solnix.io replied that they run
97 man pages and 9 KB docs, never filed a bloat report, and — separately worth knowing —
**have never queried pg_fts at all** (`idx_scan = 0` on all three of their fts indexes;
every live query path uses stock `tsvector`/GIN). Their feedback must be treated as
*unexercised in production*.

The 2.87M-doc shape is the **pgesq/agora** deployment: `ndocs 2,866,240`, `avgdl 1662.6`,
`nterms 98,646,258`, `nsegments 8`, ~31% docid gaps, open report *"VACUUM/merge do not
reclaim bloat"*.

## Why my earlier 1M-doc run found nothing

It was the wrong shape, by ~80×:

| | field | my 1M run |
|---|---|---|
| terms/doc | 1,662 | 60 |
| postings | **4.77 B** | 60 M |
| avg df | 48 | ~1 |

A fixed vocabulary modulus also gave df ≈ 1 (dictionary-dominated). The corrected harness
scales vocabulary with the corpus (`VOCAB = ndocs × 1660 / 48`) to hold df ≈ 48, and drops
`maintenance_work_mem` so multi-segment merges actually run.

## Finding 1 (P0, fixed): the index becomes permanently unvacuumable

```
ERROR:  invalid memory alloc request size 3406063183
  from: SELECT fts_vacuum('docs_fts')
  and:  CONTEXT: while cleaning up index "docs_fts" (every autovacuum cycle)
```

`gdb` gave the frame — and it was **not** where the byte count suggested:

```
#2  merge_source_load_page ()
#3  bm25_merge_segments_streaming ()
#4  bm25_merge_selected ()
#5  bm25_compact_to_one ()
#6  bm25_vacuum_compact ()
#7  fts_vacuum ()
```

**Root cause:** the dict-page walk takes `end` from `pd_lower` **read off the page with no
validation**, and the per-entry step uses an untrusted `de->termlen`. A recycled or
malformed page makes the walk overrun, `n` explodes (3.4 GB / 24 B ≈ **142 M
`MergeDictTerm` entries**, where one 8 kB page holds a few hundred), and the doubling asks
for an impossible allocation. The comment above it claimed "bounded by BLCKSZ"; it was not.

Because this sits under `bm25_merge_segments_streaming`, it killed **every merge, every
autovacuum cleanup, and `fts_vacuum`** on an affected index — the index can never be
vacuumed or reclaimed again. That is precisely the field's report.

**Fix:** clamp `end` to the page, and bounds-check every entry in *both* walks (the second
walk must use identical bounds or it writes past the arrays the first one sized).

**Verified:** the same corpus/churn sequence that failed on every attempt now completes with
**0 allocation errors**, parity exact.

## Finding 2 (fixed): huge-allocation gaps

`bm25_doclens_load`'s resident array (holds *every* docid in a segment) and `bulkdelete`'s
`carry`/`newdead` tombstone arrays used plain `palloc`/`repalloc`. The
`FTS_ALLOC_MAYBE_HUGE` macros already existed for the per-term posting arrays; these sites
were missed. Same failure class, same consequence (blocks all reclaim).

Found by grepping siblings after Finding 1 — the first fix I shipped for a 2.55 GB request
was *this*, and it did **not** clear the 3.4 GB one. Both were real; only gdb found the
second.

## Finding 3 (REPRODUCED, not yet fixed): a 45× transient bloat at nsegments=8

40k docs at field shape, three churn rounds, autovacuum only:

| round | index | nsegments |
|---|---|---|
| churn1 | 299 MB | 1 |
| **churn2** | **66,796 MB** | **8** |
| churn3 | 1,016 MB | 1 |
| settled | 1,480 MB | 1 |

The 66 GB was real (checkpoints wrote 2.1 M buffers). The index is **not permanently
bloated — it transiently explodes ~45× while segments accumulate**, then collapses when
merges catch up.

**This is very likely what the field is seeing, and it reframes their report:** their
`nsegments=8` is the *bloated* state, not a settled one. An index monitored during that
window looks like unbounded bloat that "VACUUM does not reclaim", when in fact vacuum is
being outrun (and, before Finding 1's fix, was also erroring out every cycle).

## Finding 4 (identified, not fixed): `bm25_free_page` is one WAL record per page

`fts_vacuum` on a 3.8 GB index ran **113+ minutes** without finishing. `gdb` sampling showed
steady progress (not a hang) inside:

```
#2  bm25_free_page ()   <- GenericXLogStart/Finish PER PAGE
#3  bm25_free_chain ()
#4  bm25_free_segment ()
```

~489 k pages × a full `GenericXLog` delta each ≈ 14 ms/page. Same class as the 1.6.1 P0:
correct answer, unusable duration. Needs WAL batching across freed pages — a real change
requiring its own measurement, deliberately **not** rushed into this release.

## Release decision

Ship Findings 1 + 2: they convert a permanently-unvacuumable index into a vacuumable one,
which is the field's actual blocker. Findings 3 + 4 are documented, reproduced, and left
open with named next steps rather than half-fixed.

## Harness corrections (each cost a run)

* `%%` in a non-printf script reached SQL literally.
* `(B+g)*7919` overflowed int32 at 10 M+ ids → `integer out of range`; needs `::bigint`.
* Parity used a *computed* term that did not exist → vacuous `0 = 0` "pass". Now takes the
  term from a live row and fails loudly if `regex_count = 0`.
* `@@@`, not `@@`, is the match operator.
