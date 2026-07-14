# Meta+WAH for trigram intersection — assessed, not implemented (no target)

**Paper:** Velez, Ingerson, Sawin, Chiu, *Improving Bitmap Execution Performance
Using Column-Based Metadata* (FiC 2016), `VSIC-FiC16.pdf`. It adds small
compression-time metadata to **WAH-compressed bitmaps** so a **bitwise AND/OR of
two large WAH bit-vectors** can short-circuit skippable words (query-*speed*
gain; the metadata *adds* ≤3.5% storage).

## Why it was not implemented

Directed to implement Meta+WAH "for trigram-set intersection only." On
inspecting the actual code, **pg_fts performs no such intersection** — there is
no target for the technique:

- The trigram candidate path is `bm25_trgm_candidates()`
  (`pg_fts_trgm_index.c`). For a fuzzy/regex term it **UNIONs** each pattern
  trigram's *term-ordinal* set and dedups (`sm_next_member` enumeration +
  `qsort`/unique), then unions the matching terms' docid postings. It is a
  union of small ordinal sets, **not** an AND of large docid bitmaps.
- The sparsemap operations pg_fts calls are `sm_next_member` (enumerate),
  `sm_contains` (membership), and `sm_add_grow` (build). **`sm_intersection`
  is never called anywhere in pg_fts** — it is dead vendored API in
  `vendor/sm.c`.
- pg_fts's posting lists are frame-of-reference bit-packed columns
  (`pg_fts_for.h`), not WAH bitmaps, so WAH-specific metadata does not apply to
  them either.

Meta+WAH optimizes an operation (large-bitmap bitwise AND with short-circuit
skipping) that pg_fts does not run. Implementing it would require first
*inventing* an intersection-based trigram algorithm to replace the working
union-based one — building work solely to justify the technique — and would then
optimize a minority query path (fuzzy/regex candidate generation) that is not a
bottleneck, while *adding* index storage (the opposite of the stated size goal).

## What already fills the paper's *conceptual* role

The paper's core idea — precomputed skip-metadata that lets boolean evaluation
skip ahead — is already realized in pg_fts, in the form appropriate to its
FOR-packed postings: **block-max WAND** with per-128-doc-block `max_tf` bounds
and `wand_seek` / `wand_skip_blocks`, which skip whole posting blocks that cannot
beat the running top-k threshold (`pg_fts_am_scan.c`).

## Verdict

No implementation, no benchmark, no release: there is no operation for Meta+WAH
to accelerate. For the index-*size* gap (the actual competitive weakness), the
lever remains the ROADMAP doclen-sidecar (doclen stored once per posting today,
~38–45% of the index), which is unrelated to this paper.
