# Property-based tests (hegel-c)

Standalone [hegel-c](https://github.com/gburd/hegel-c) property tests for the
**pure-C** cores of pg_fts. These exercise code that has zero PostgreSQL backend
dependencies, so they run as an ordinary C program (they do **not** load into a
backend and are **not** part of `make installcheck` / `make check`).

Coverage:

- `test_for.c` — the Frame-of-Reference integer codec (`pg_fts_for.h`:
  `bm25_bitwidth`, `bm25_for_pack`, `bm25_for_unpack`, `bm25_for_bytelen`,
  `bm25_for_get`). The compression core of the bm25 posting blocks; guards the
  P1 doclen-sidecar (format v3) work.
- `test_lev.c` — the Levenshtein automaton (`pg_fts_lev.c`:
  `fts_lev_start/step/accept/match_prefix`), compared against an independent
  naive edit-distance oracle.

Both include the real source directly (the header / the `.c`), so the tests and
the extension share one copy — no duplicated logic to drift.

## Prerequisites

- C99 compiler, CMake 3.14+
- libcbor, zlib, cmocka
- the `hegel` server binary (from hegel-core); the library spawns it as a
  subprocess. Override its path with `HEGEL_SERVER_COMMAND` if it is not on
  `PATH`.

hegel-c itself is fetched automatically via CMake `FetchContent` from
`https://github.com/gburd/hegel-c.git` (`GIT_TAG main`).

## Run

```bash
cd test/hegel
cmake -S . -B build
cmake --build build
# if the hegel binary is not on PATH:
#   export HEGEL_SERVER_COMMAND=/path/to/hegel
ctest --test-dir build --output-on-failure
```

## Properties

FOR codec (`test_for.c`):

- **Round-trip** — `unpack(pack(vals)) == vals` for n in 0..128, full uint64
  range. Core P1 guard.
- **Random-access consistency** — `bm25_for_get(buf, i) == unpack(buf)[i]` for
  every i.
- **Byte-length contract** — bytes packed equal bytes unpacked equal
  `bm25_for_bytelen`; and `1` for the all-zero column, else `1 + (n*w+7)/8`.
- **Bitwidth minimality** — `bm25_bitwidth(v)` is the minimal bits for v (0 for
  0, 64 for `UINT64_MAX`), with `v < 2^w` and `v >= 2^(w-1)`.

Levenshtein (`test_lev.c`):

- **Oracle equivalence** — the DFA accepts iff independent byte-wise edit
  distance `<= k` (query length bounded by `FTS_LEV_MAXQ`, the extension's own
  fallback threshold).
- **Robustness / no-crash** — arbitrary query + candidate bytes and any k never
  crash; the reported dead-prefix length stays in `[0, candlen]`.

Generators are deliberately broad (full uint64, boundary values 0 / 1 / powers
of two / `UINT64_MAX`, n drawn separately to reach full 128-value blocks). Do
not narrow them — the boundaries are the test.
