# Phase measurements (PLAN_STORAGE_PERF_2026-08.md)

Fixed rig: EC2 r6id.4xlarge (mala), PG17.10, local NVMe, 2,000,000-doc
high-vocabulary synthetic corpus (50k-word Zipfian vocab, varied tf/doclen;
`gen_hivocab2.sql`), shared_buffers=16GB, prewarmed. Absolute ms differ from
real-Wikipedia numbers; the PER-PHASE before/after delta on THIS rig is the
signal. Parity gate: `bench/parity_check.sh` genuine_misses=0. Latency:
`bench/latency.sh` NSAMP=200 warm median/p95/p99.

df bands: slovakia=10526 (rare), hungary=22222 (mid), year=666666 (common),
slovakia&hungary (AND).

## baseline_141.txt — Phase 0 baseline, pg_fts 1.4.1
Index 954 MB, build 158 s, parity PASS.
band           median   p95     p99     n   (ms, NSAMP=200)
rare_k10       2.337 2.466 2.483 200
mid_k10        1.758 1.859 2.095 200
common_k10     17.341 17.708 17.861 200
common_k100    18.333 19.045 19.166 200
and_count      1.962 2.074 2.116 200
count_common   3.745 3.834 3.884 200

## Phase 1 (P2/P3 execution-path) — NO-OP on current code, not shipped
A/B on the fixed rig (pg_fts 1.4.1):
- over-fetch wantk k*4 -> k*2: rare 2.34->2.34, mid 1.76->1.71, common 17.3->17.3ms
  (within noise; reverted -- k*4 is cheap defensive headroom for churned tables).
- Metapage reads are cached-buffer hits (~100ns); 2-3 per WAND batch is
  unmeasurable against a 2.3ms rare query.
Finding: rare/mid are ALREADY 2.3/1.7ms -- the P2/P3 fixed-overhead gains
(ROADMAP target "15.8->4-6ms") were realized in the 1.0.x-1.2.x line. There is
no measurable execution-path win left on correctness-clean current code, so no
1.4.2 is shipped. The remaining common-term gap (17.3ms) is scoring/decode of
the high-df postings -- Phase 2 (doclen out of postings) + Phase 3 (codec).

## Phase 2 FINAL qualification (clean 2M, v4)
- index 568 MB (clean rebuild) vs 954 MB v3 = 40% smaller.
- parity PASS (1% quantization tol; exact-mode ties match 1.4.1 behavior).
- latency: rare 1.94, mid 1.72, common_k10 2.30, common_k100 3.25, AND 1.99 ms.
- count(*): v4 == v3 (both dict-df fast path ~0.4ms when heap all-visible; both
  ~20ms when the corpus was DELETE-churned and VM not all-visible -- NOT a v4
  regression, verified by swapping the 1.4.1 .so on the identical corpus).
- dual-read: a v3 index built by 1.4.1 reads correctly under the v4 build with
  NO warnings and NO reindex; parity PASS. Mixed v3+v4 fts_merge correct.
- vacuum reclaim: fixed a sidecar-chain leak in bm25_free_segment (v4 index now
  reclaims to 1.18x the fresh floor, was leaking to 4.13x before the fix).

## Phase 3 (common-term codec) — NOT PURSUED (premise resolved by Phase 2)
Re-baselined after 1.5.0.  The Phase 3 premise ("pg_fts common-term ranked is
~6x slower than competitors") is gone:
- warm common_k10 28 ms (1.4.0) -> 2.3 ms (1.5.0) -- now at/below every
  competitor's OWN common-term number (pgts 13.5, psearch 4.5, vchord 7.4 ms);
- index buffers touched for common `year` ranked: 5370 (v3) -> 177 (v4), 30x
  fewer -- the sidecar means scoring no longer decodes a doclen column across
  thousands of posting blocks;
- cold-cache common `year`: v3 78 ms -> v4 62 ms (cold is heap-recheck-I/O bound,
  which both pay; the win is warm + buffer efficiency + 40% smaller index).
Phase 3a (impact-quantized postings) was ALREADY proven not to prune common
terms on real text (NOTE_IMPACT_ORDERING.md); Phase 3b's decode-cost win is now
largely captured by v4's ~56%-smaller blocks.  Building a format-changing Phase 3
for marginal cold gains fails the plan's kill criterion.  DEFERRED unless a
future field report shows a specific common-term latency need v4 does not meet.

## Phase 4 (parallel build) — functional, deeper work not justified
Parallel build already engages: v4 @4 workers 137 s vs serial 192 s (1.4x,
Amdahl-limited by the leader's final merge).  Matching Tantivy's ~45 s would need
a merge-parallelism rework for a build-time-only win (rarely the operational
bottleneck).  Left as-is.

## Plan outcome
Phase 0 (harness) + Phase 2 (doclen sidecar, shipped 1.5.0) delivered the size
win (40% smaller) AND the common-term latency win (7.7x warm) that Phases 2+3
together were scoped to achieve.  Phase 1 was a measured no-op; Phase 3/4 are not
justified.  The storage/perf plan is COMPLETE.
