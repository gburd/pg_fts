# Deferred / tracked issues

## Intermittent crash under very heavy concurrent read+insert+merge+vacuum (t/006)

**Status:** open, tracked. Non-gating on the Debian CI runner (t/006 runs in a
separate `continue-on-error` step); still gating in the Nix tap-pg17/tap-pg18
checks, where it is stable.

**Symptom:** under sustained concurrent churn on ONE index (a dedicated
`fts_merge`+`fts_vacuum` loop + several INSERT/DELETE loops + several
`count(*) @@@` readers, ~20-25 s), a backend rarely SIGSEGVs. The test's real
invariants all pass first (no "unexpected data beyond EOF", no query ERROR, no
anchor-miss, stable count); the crash trips teardown (`Tests: 5 Failed: 0`,
"exited 29, no plan"). Reproduced locally once on PG18; did NOT re-trigger on
several subsequent 25 s runs, and a clean shutdown never crashes -> rare,
timing-dependent.

**What is known:**
- It is the pre-existing scan-vs-merge page-recycle race class. The 1.2.1
  defensive work (deletion-XID recycle gate, `tidset_sane`, dict/pending/decode
  bounds guards, `df` clamp) REDUCED it but did not fully close every timing
  window.
- All captured cores show the SHUTDOWN cascade (`_dl_fini` -> a bogus fini
  pointer `0x6220`, identical across WAL writer / autovac / bgwriter / backend)
  -- an artifact of the nix-built `.so` unload under glibc 2.42 AFTER the
  postmaster SIGQUITs everyone; NOT the primary crash. The primary crasher's
  core was overwritten by the cascade before it could be inspected.

**To fix properly (do NOT ship a plausible-but-unproven concurrency fix -- a
crash is worse than the current rare flake):**
1. Get a RELIABLE repro with the PRIMARY stack: run the churn with
   `restart_after_crash=off`, a unique `core_pattern` per PID that is NOT
   overwritten, and ideally an ASan build (the CI `sanitizers` recipe:
   clang `-fsanitize=address -shared-libasan`, preload the matching asan
   runtime) so the first out-of-bounds access is caught at its source rather
   than surfacing later as a SIGSEGV.
2. Localize which reader/merge path still touches a recycled page (the recycle
   gate covers `bm25_new_buffer`, but a page freed and re-extended within the
   same op, or a stale metapage snapshot older than the generation re-check
   window, may still slip through).
3. Fix at the source, re-run t/006 in a loop (>= 50 iterations) on both PG17 and
   PG18 with ASan clean, then restore t/006 to the gating TAP step and remove
   this entry.

**Not blocking:** the size/latency root-cause work (fts_vacuum reclaim fix,
query-form finding) and the competitive benchmark are unaffected; this is a
separate, rare, pre-existing concurrency window.
