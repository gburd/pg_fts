# Deferred / tracked issues

## (RESOLVED 2026-07-30) Crash under concurrent read + fts_vacuum

**Root cause found via AddressSanitizer and FIXED.**

The intermittent SIGSEGV under heavy concurrent read+insert+merge+vacuum was a
consequence of the size-regression fix from the same session. That fix bypassed
the deletion-XID recycle gate during compaction (so `fts_vacuum` could repack
freed pages in one pass and actually shrink). But the bypass was keyed only on
"compaction context" (`bm25_lowfree` active), and `fts_vacuum` /
autovacuum-cleanup run under **ShareUpdateExclusiveLock**, which does NOT
conflict with a scan's AccessShareLock. So a concurrent reader could be copying
a segment's pages (e.g. a livedocs tombstone blob via `bm25_read_blob`) while
`fts_vacuum` recycled and overwrote them -> the reader's sparsemap walk followed
a garbage internal offset and made a wild memory access that corrupted
`CurrentMemoryContext`, surfacing as a SEGV in the next `AllocSetAlloc`
(ASan stack: `bm25_eval_query` palloc <- bm25_collect_matches <-
bm25_count_visible <- FtsCountExecScan).

Fix (committed):
- `bm25_page_recyclable()` bypasses the recycle gate ONLY when we actually hold
  `AccessExclusiveLock` (`CheckRelationLockedByMe`), not merely when in a
  compaction context. Under SUEL the gate stands, so a concurrent scan is never
  handed a page it might still be reading.
- `fts_vacuum()` now takes `AccessExclusiveLock` (like REINDEX), so its
  single-pass vacate+pack shrink is safe (no concurrent scan) and still works
  (verified: fresh 143MB index -> fts_vacuum -> 60MB).
- Autovacuum cleanup keeps SUEL + the gate: it reclaims across passes as XID
  horizons advance instead of corrupting a concurrent scan.

Verified: 8 rounds of the t/006 concurrent churn under ASan (clang
-fsanitize=address -shared-libasan) — ZERO errors; previously ASan caught the
SEGV within 1-2 rounds. t/006 restored to the gating CI TAP set.

Reproduction recipe (kept for future use): build the .so with
`COPT='-fsanitize=address -fno-omit-frame-pointer -g -O1 -fno-lto'
SHLIB_LINK='-fsanitize=address -shared-libasan'`, run the backend with
`LD_PRELOAD=<libclang_rt.asan-x86_64.so>:<gcc-15 libstdc++.so.6>` (the newer
libstdc++ must precede so CXXABI_1.3.15 resolves over asan's gcc-13 one) and
`ASAN_OPTIONS=halt_on_error=1:print_stacktrace=1:log_path=...:verify_asan_link_order=0`,
then loop the read+insert+merge+vacuum churn.
