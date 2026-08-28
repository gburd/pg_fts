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
