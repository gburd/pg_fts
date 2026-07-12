# Contributing to pg_fts

Thanks for your interest in pg_fts. This document describes how to build, test,
and submit changes.

## Where development happens

- **Canonical repository:** <https://codeberg.org/gregburd/pg_fts> (Codeberg).
  Open issues and pull requests here.
- **GitHub mirror:** <https://github.com/gburd/pg_fts> is an automatic mirror of
  Codeberg. PRs opened on the mirror are welcome, but the Codeberg repository is
  where releases are cut and where CI + review gate the merge.

## Building

The primary build path is **PGXS** against an installed PostgreSQL (>= 17). This
is what packagers and users run and what CI gates on:

```sh
make PG_CONFIG=/path/to/pg_config
sudo make install PG_CONFIG=/path/to/pg_config
```

`PG_CONFIG` defaults to whatever `pg_config` is on `PATH`. You need a C
toolchain and the PostgreSQL server headers (`postgresql-server-dev-*` or a
source install exposing `pg_config`).

On Windows with MSVC (where PostgreSQL is built with meson, not PGXS), use the
meson recipe against an MSVC-built PostgreSQL >= 17 (see `meson.build`).

### Nix flake (the maintainer path)

With [Nix](https://nixos.org) (flakes) you can build and run the full test
matrix without a local PostgreSQL install. This is how the maintainer and CI
reproduce the release gate:

```sh
nix build .#default          # build against nixpkgs PostgreSQL 17
nix flake check              # build + regression/isolation, PG 17 and 18
nix develop                  # dev shell with the toolchain + pg_config
nix run .#docs               # validate doc/pg_fts.sgml (well-formedness)
nix run .#docs-html          # render doc/pg_fts.sgml -> doc/html/pg_fts.html
```

The two checks that gate a release are:

```sh
nix build .#checks.x86_64-linux.installcheck-pg17
nix build .#checks.x86_64-linux.installcheck-pg18
```

Both must exit 0.

## Testing

The regression + isolation suites are the correctness gate. Run them against a
running server with PGXS:

```sh
make installcheck PG_CONFIG=/path/to/pg_config
```

`make installcheck` runs:

- **Regression** (`REGRESS`): `sql/pg_fts.sql`, `sql/unicode_fold.sql`,
  `sql/idx_scan_stats.sql` — types, query language, the bm25 index, ranking,
  maintenance, and the MVCC/tombstone/oversized-doc correctness edges.
- **Isolation** (`ISOLATION`): `specs/bm25_concurrency.spec`,
  `specs/bm25_cic.spec` — MVCC snapshot stability, pending-list visibility,
  VACUUM/merge invisibility to an open scan, tombstone reuse, and
  CREATE/REINDEX INDEX CONCURRENTLY.
- **TAP** (`TAP_TESTS`): `t/001_crash_recovery.pl` (crash + WAL replay),
  `t/002_replication.pl` (streaming standby). TAP tests need a
  `--enable-tap-tests` PostgreSQL build and the `IPC::Run` Perl module.

Under the flake, `nix flake check` runs REGRESS + ISOLATION for PG 17 and 18.

Standalone property-based tests (hegel-c) for the pure-C codec/automaton cores
live in `test/hegel/` and are separate from `make installcheck` (they need
extra deps: hegel-c, libcbor, cmocka, the `hegel` binary).

## Coding style

Match the existing code — it follows PostgreSQL's own conventions:

- **PostgreSQL C style**: tabs for indentation, `pgindent`-compatible layout,
  `snake_case` for functions and variables. When in doubt, read a neighbouring
  file.
- **Every page write goes through `GenericXLog`.** There are zero raw
  `XLogInsert`, `log_newpage`, `MarkBufferDirty`, `PageSetLSN`, or
  `smgrwrite`/`smgrextend` sites in the extension, and that invariant is what
  makes the index crash-safe and physical-replication-safe. New index-writing
  code must use `GenericXLogStart`/`GenericXLogRegisterBuffer`/`GenericXLogFinish`.
- **No new compiler warnings under `-Wall`.** The vendored sparsemap
  (`vendor/sm.c`) is the only translation unit with warning suppressions, and
  those are scoped to it in the `Makefile`.
- **Vendored code** (`vendor/`) keeps its upstream style; its public symbols are
  namespaced (`__pg_bm25_*`) so a second copy loaded by another extension cannot
  collide.

Format the C with the project `clang-format` (available in `nix develop` via
`clang-tools`).

## Submitting a pull request

1. Open the PR against the Codeberg repository (the GitHub mirror also works but
   the gate runs on Codeberg).
2. CI builds and runs REGRESS + ISOLATION against PostgreSQL 17 and 18. Both
   must pass. (PG 19/devel runs non-fatally, since it may not be packaged on the
   runner.)
3. Changes to the traversal core (the `fts` access method, the scan/WAND paths)
   or the query parser get an additional independent review and are gated on the
   PG 17 + PG 18 matrix before merge.
4. Keep the regression suite green and add coverage for new behavior. A
   correctness-affecting change without a test will be asked for one.

There is **no CLA and no sign-off requirement** (no DCO). By contributing you
agree your contribution is licensed under the project's PostgreSQL License (see
`LICENSE`).

## Reporting bugs

Open an issue on Codeberg. For a **security** issue, do not open a public issue —
see `SECURITY.md`.
