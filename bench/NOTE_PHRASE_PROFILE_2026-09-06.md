# Phrase query profiling (2026-09-06)

Profiling the phrase path, which the 1.5.10 wrap-up flagged as the highest-value
unexamined target. It found something worse than a slow path: **the number I
published for phrase in the 5-way benchmarks was not measuring a phrase.**

## Correction: the published "phrase 90.70 ms" was an AND query

`RESULTS_5WAY_159b` (and 159 before it) list pg_fts phrase at 90.70 ms. The query
was written as:

```sql
to_ftsquery('english','''united states''')
```

Single quotes, doubled for SQL escaping. That parses to **`('unit' & 'state')`** --
a plain conjunction. pg_fts phrase syntax uses **double** quotes:

```sql
to_ftsquery('english','"united states"')   -- ('unit' <-> 'state')
```

So the benchmark compared a pg_fts AND against pg_search's real `###` phrase.
Verified on the host by printing the parse tree. Both result files now carry a
correction pointing here.

## The real phrase numbers (2.19M Wikipedia, r6id.4xlarge, medians of runs 4-8)

Ranked top-10, `fts_search`:

| phrase | matches | `positions=off` (default) | `positions=on` | speedup |
|---|---|---|---|---|
| "united states" | 361,465 | **8,384.60 ms** | **229.19 ms** | **36.6x** |
| "new york" | 195,558 | 4,853.02 ms | 128.72 ms | 37.7x |
| "world war" | 130,190 | 4,346.64 ms | 118.97 ms | 36.5x |

Exact `count(*)` of a phrase:

| | `positions=off` | `positions=on` | speedup |
|---|---|---|---|
| count("united states") = 361,465 | 7,169.96 ms | **132.09 ms** | **54.3x** |

Index size: 1421 MB (off) vs **2626 MB** (on) -- 1.85x. Build 352 s vs 236 s.

So the honest position is: **phrase is 4-8 SECONDS with default settings, and
119-229 ms with `positions=on`.** Neither is 90 ms. The default is far worse than
published and the tuned configuration is far better than published.

## Why the default is so slow

With `positions=off` a phrase cannot be verified from the index, so
`bm25_collect_matches()` falls back to AND + **heap recheck**: it re-reads the
`ftsdoc` for every doc containing all the terms and re-checks adjacency. For
"united states" that is a heap probe per candidate over a 2.19M-row table.

With `positions=on`, `bm25_phrase_eval_seg()` verifies adjacency directly from
stored positions -- no heap access at all. This is exactly the "cliff fix" the
code comments describe, and it works: 36-54x.

## Where the remaining 229 ms goes (positions=on)

```
24.40%  bm25_topk_candidates_range   <- the WAND ranking scan
21.17%  bm25_collect_matches         <- materializing the FULL match set first
13.99%  bm25_decode_term
 8.36%  bm25_doclen_cursor_lookup
 4.44%  bm25_doclen_cursor_load_page
 4.33%  fts_phrase_step_pos          <- the actual adjacency check
```

**The adjacency test is only 4.33%.** The cost is that a ranked phrase must
materialize the entire exact match set (all 361,465 docids) *before* WAND can
rank, then gate the WAND traversal against it through a `DocidFilter`.

This is a known asymmetry in our own design, documented in
`bm25_topk_candidates_range`: pure-boolean AND/NOT got a **lazy `BoolGate`** that
evaluates the query over cursor-presence at admission time with no collect pass
("`year & hungary` no longer materializes all 735k `year` postings"). Phrase was
explicitly left on the old collect-first path, because adjacency is not a function
of which cursors sit at the pivot.

**The opportunity:** a phrase gate that verifies adjacency lazily at admission
time -- when WAND offers a pivot doc, decode just that doc's positions for the
phrase terms and run `fts_phrase_step_pos`. For a top-10 query that is ~10-100
adjacency checks instead of 361,465, and it would remove the 21% collect plus much
of the decode. Not attempted here: it needs the position bytes reachable per-doc
from the WAND cursor, which is a real change to the cursor, and it must preserve
the exactness parity_check enforces. Sized as the next phrase work item.

## Actions taken

- Corrected `RESULTS_5WAY_159b_2026-09-06.md` and `RESULTS_5WAY_159_2026-09-05.md`
  in place: the phrase row is an AND, with a pointer here.
- **`positions=on` is now documented as required for usable phrase performance**
  in the README/docs phrase section -- previously the option was described as
  enabling "index-only" phrase without stating that the default costs seconds at
  scale.

## Caveat on the comparison

pg_search's phrase (22.86 ms via `###`) is still ~5-10x faster than our
`positions=on` phrase, on an index 2734 MB vs our 2626 MB -- i.e. at comparable
size once positions are enabled, and it does not stem. The 36-54x default-vs-tuned
gap is ours to own; the residual gap to pg_search is the lazy-gate work above.
