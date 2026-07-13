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
- `test_for_props.c` — FOR codec **safety/bounds** (`pg_fts_for.h`), complementing
  `test_for.c`'s round-trip: unpack write/read bounds, `bytelen` vs `unpack`
  agreement, and corrupt-width (>64) safety. Guards the exact overflow the
  posting-decode crashes came from; run under ASan.
- `test_docvalid.c` — the structural FtsDoc validator (`pg_fts_docvalid.h`:
  `fts_doc_check`), the trust boundary for a hostile/corrupt ftsdoc datum.
  Builds valid images byte-for-byte like `fts_doc_build()` and mutates them.

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

FOR codec safety (`test_for_props.c`, complements `test_for.c`):

- **Unpack bounds** — `bm25_for_unpack(buf, n, out)` writes exactly `n` values
  (canary just past `out[n]` untouched) and returns exactly
  `bm25_for_bytelen(buf, n)` bytes consumed, for every width `0..64` and n.
- **Bytelen agreement** — `bm25_for_bytelen(buf, n)` equals `bm25_for_unpack`'s
  return for all widths `0..64`; column-skip and column-decode advance the
  stream by the same amount.
- **Corrupt-width safety** — a width byte `65..255` (never produced by pack,
  reachable via on-disk corruption) stays inside exact-size `buf`/`out`
  allocations: garbage values allowed, OOB read/write is not (ASan-enforced).

FtsDoc validator (`test_docvalid.c`):

- **Accepts well-formed** — an image serialized byte-for-byte like
  `fts_doc_build()` (header, entries[nterms], lexemes, MAXALIGN, positions[])
  is accepted for `sz == VARSIZE`.
- **Monotone truncation** — cutting readable `sz` or declared VARSIZE below the
  true image size is rejected (fails closed on any short read).
- **OOB mutation rejected** — a single field bumped so a derived offset
  provably escapes the buffer (nterms, lexbytes, an entry `len`, a term `tf`,
  or a sub-header VARSIZE) is rejected — the contrapositive of
  "accept implies in-bounds".
- **Fuzz no-OOB** — arbitrary bytes + arbitrary declared VARSIZE over an
  exact-size allocation return a clean boolean without reading past `sz`
  (ASan-enforced).

Generators are deliberately broad (full uint64, boundary values 0 / 1 / powers
of two / `UINT64_MAX`, n drawn separately to reach full 128-value blocks). Do
not narrow them — the boundaries are the test.
