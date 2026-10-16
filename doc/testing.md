# Testing

pg_fts is a PostgreSQL index access method: a bug here can corrupt an index,
crash a backend (which force-rolls-back every other backend), or silently return
wrong search results. Trust in code like this is earned method by method, so
this page is an honest accounting of how pg_fts is tested. Every method below
runs in CI on both GitHub and Codeberg on every push and pull request.

## Correctness: regression + isolation

The core gate is the PostgreSQL regression suite (`sql/pg_fts.sql` vs
`expected/pg_fts.out`, plus `unicode_fold` and `idx_scan_stats`) and the
isolation suite (`specs/bm25_concurrency.spec`, `specs/bm25_cic.spec`,
`specs/bm25_vacuum_growth.spec`), run via
`make installcheck` against PostgreSQL **17, 18, and 19**. The regression suite
exercises the full query language (boolean, phrase, NEAR, prefix, fuzzy, regex),
ranking (`<=>`, all five BM25 variants, BM25F), the count pushdown, the index
build/insert/vacuum/merge lifecycle, and the type I/O round-trips. The isolation
suite covers MVCC correctness, `CREATE INDEX CONCURRENTLY` / `REINDEX
CONCURRENTLY`, concurrent DML + VACUUM + merge, and that a VACUUM which cannot
truncate (another session holds a lock on the index) does not grow the file.

## Memory safety: AddressSanitizer + a fuzz gate

Two of pg_fts's shipped bugs (0.3.3, 0.3.4) were memory-safety bugs on the
paths that parse untrusted on-disk bytes — a buffer overflow the plain
regression suite ran straight past because it only feeds *valid* data. Those are
now guarded two ways:

- **Fuzz / corruption harness** (`test/fuzz/`, gating). Standalone
  AddressSanitizer + UndefinedBehaviorSanitizer fuzzers drive random and
  deliberately-corrupted bytes at the functions that parse on-disk data — the
  frame-of-reference codec (`bm25_for_unpack`), the stored-document validator
  (`fts_doc_is_valid`), and the segment block-header decoder. The property is
  simple: **these must never overflow or crash on any input** — they reject it
  or handle it safely. The harness carries its own teeth: three planted-bug
  builds (an un-clamped count, a signed-count bypass, a corrupt width) that
  *must* abort under ASan, so a regression that removed a guard would be caught
  by the harness failing to catch it.
- **In-process AddressSanitizer run** (`sanitizers` CI job, gating). The
  memory-critical SQL paths -- index build, ranked and boolean scans, bulkdelete,
  VACUUM compaction and tail truncation, segment merge -- run against a
  PostgreSQL that is itself built with AddressSanitizer, with an ASan-built
  `pg_fts.so` loaded into it, so server and extension share one runtime and the
  in-process paths run instrumented.  An earlier version loaded the instrumented
  `.so` into a stock `pg_virtualenv` postmaster; that never worked (the asan
  runtime was not on the server's loader path, so `CREATE EXTENSION` could not
  load the library) and the job was `continue-on-error`, so it reported success
  while running nothing -- fixed by building the server with ASan too.  ASan
  enlarges every stack frame, so the job raises the OS stack limit (`ulimit -s
  32768`) and `max_stack_depth` (24 MB) together and runs with
  `ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=0` (the one-shot
  client programs leak small buffers on exit by design; keeping real-sized frames
  lets the raised stack depth hold).  The job runs a focused subset, not every
  regression test: a few tests load large synthetic high-repetition corpora whose
  per-posting work is impractically slow under ASan's ~15x slowdown, and they add
  no memory-path coverage the focused set lacks.  The job fails on any ASan memory
  error in the server log.

## Property-based tests (hegel)

`test/hegel/` states invariants that must hold for *all* inputs, checked over
generated and shrunk cases via [hegel-c](https://github.com/gburd/hegel-c):
the FOR codec round-trips and never writes past the caller's buffer for any
width or count; the Levenshtein automaton matches a reference; the stored-document
validator accepts every well-formed document and rejects every out-of-bounds
mutation. (This job is best-effort in CI, since it needs the `hegel` server;
the same surface is gated by the fuzz job.)

## Torn-page / corruption crash-safety (TAP)

`t/003_corruption.pl` builds an index, then writes bad bytes directly into the
index file — a corrupt block-header count, and a coarse content smash — and
asserts that scans and VACUUM over the damaged index **do not crash the
backend**: a corrupt block is a bounded miss with a `WARNING`, never a segfault.
`t/001_crash_recovery.pl` and `t/002_replication.pl` verify WAL crash recovery
and physical replication of the index.

## Coverage

CI measures line coverage of the pg_fts sources (`ci/coverage.sh`, gating) and
fails if it drops below **90%**. The vendored sparsemap (`vendor/sm.c`, whose
API is mostly unused by pg_fts) is reported separately and not part of the gate.
Coverage is a floor, not the goal — the fuzz, property, and corruption tests
exist to exercise the *adversarial* inputs that a line-coverage number alone
would not.

## Portability

The extension builds and its suite runs on PostgreSQL 17, 18, and 19, via both
PGXS (`make PG_CONFIG=...`) and the Nix flake (`nix flake check`). It has been
built on x86-64, ARM64, and RISC-V, and on Linux, FreeBSD, and Windows (MSVC).
