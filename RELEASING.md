# Releasing pg_fts

Releases are **tag-triggered**. The version lives in `META.json` and
`pg_fts.control` (and the `pg_fts--<version>.sql` filename); the git tag is
`v<version>` (e.g. `v0.1.0`).

## Cut a release

1. Bump the version everywhere it appears and land it on `main`:
   - `pg_fts.control` `default_version`
   - `META.json` (`version` in two places; leave `meta-spec.version` = 1.0.0)
   - rename `pg_fts--<old>.sql` → `pg_fts--<new>.sql` and update `Makefile`
     `DATA`, `meson.build`, `flake.nix`, and the `CREATE EXTENSION ... VERSION`
     line in `sql/pg_fts.sql` + `expected/pg_fts.out`
   - add a `CHANGELOG.md` entry
2. **If the release changes the on-disk index format, provide an in-place
   upgrade path (see "On-disk format changes" below) — do NOT ship a
   format change that forces a REINDEX unless it is genuinely impossible to
   migrate in place.**
3. Tag and push (Codeberg is `origin`; it auto-mirrors to the GitHub mirror):
   ```sh
   git tag -a vX.Y.Z -m "pg_fts X.Y.Z — <summary>"
   git push origin vX.Y.Z
   ```

## Storage / WAL / crash-recovery review checklist (per release)

pg_fts is a single-author project; this checklist is the standing "second set of
eyes" for any change that touches the storage, WAL, crash-recovery, page-recycle,
or concurrency paths.  Work through it before tagging a release that modifies
any of `pg_fts_am.c` / `pg_fts_am_scan.c` / `pg_fts_customscan.c` /
`pg_fts_migrate.c` or the on-disk structures in `pg_fts_am.h` / `pg_fts_for.h`.
A change confined to analysis/query-parse/ranking value code (no page or catalog
effect) can skip it.

- [ ] **All page mutations go through `GenericXLog`.** No new
      `log_newpage`/`XLogInsert`/`smgrwrite`/direct buffer flush; no custom
      resource manager.  (`grep -nE 'log_newpage|XLogInsert|smgrwrite' *.c` is
      empty.)
- [ ] **Atomic publish point preserved.** A built/flushed/merged segment is
      written while invisible and published by a single metapage record; a
      crash leaves the old state or the new state, never a torn structure.
- [ ] **Standby-safe page recycling.** A freed page is not reused until its
      free-XID horizon has passed (`bm25_page_recyclable`); any new recycle site
      honors the gate, and any gate bypass is justified by an exclusive lock
      (`CheckRelationLockedByMe(..., AccessExclusiveLock)`).
- [ ] **No write path runs during recovery.** New SQL-callable functions that
      write WAL call the recovery guard (`RecoveryInProgress()` &rarr; error);
      AM callbacks are exempt (core never invokes them in recovery).
- [ ] **Privilege check on any function that opens an index by OID or exposes
      indexed content.** Maintenance functions require index ownership; content
      functions are revoked from `PUBLIC` in the install + upgrade SQL.
- [ ] **Bounded miss, never crash.** Any new decode of page-derived bytes
      bounds-checks lengths against the page before trusting them, and degrades
      to a bounded wrong-count rather than an out-of-bounds read; a
      corresponding fuzz/property case exists.
- [ ] **Cancellation.** Every new long loop polls `CHECK_FOR_INTERRUPTS()` with
      no lock held across the yield.
- [ ] **Corpus statistics count only live documents** (build callback gates
      `ndocs`/`sumdoclen` on `tupleIsAlive`; merge accumulation uses
      `ndocs - ndeleted`).
- [ ] **On-disk format change?** If yes, bump `BM25MetaPageData.version`, read
      both old and new formats, ship as a MINOR release with a real old-format
      TAP test, and add the upgrade path (see below).  A forced REINDEX is a
      release blocker.
- [ ] **Full gate green on the supported majors (17, 18):** `installcheck`,
      isolation, TAP (incl. crash-recovery `t/001`, replication `t/002`,
      pinned-horizon `t/009`), `make check-ascii`, `make check-alloc`, the fuzz
      harness (`== ALL CLEAN ==`), and coverage &ge; 90% of pg_fts-own sources.
- [ ] **Concurrency/traversal-core change?** Get a second review (a reviewer
      sub-agent or a human) and, for anything scale-sensitive, an A/B on real
      hardware before shipping &mdash; do not ship a plausible-but-unproven
      concurrency fix (a crash is worse than the bug it claims to fix).

## On-disk format changes (MANDATORY upgrade path)

**Rule: any release that changes the on-disk index format MUST ship an upgrade
path that preserves existing indexes built by the immediately-preceding minor
version. A format change that forces users to `REINDEX` (drop + rebuild) is not
acceptable** — for a large index (the field's is ~84 GB, ~48 min to build) a
forced rebuild is an outage and a data-availability risk (needs a second full
copy on disk). Treat "users must REINDEX" as a release blocker, not a footnote.

What counts as a format change: anything that alters the bytes a *previously
built* index has on disk or how they are interpreted — the metapage struct
(`BM25MetaPageData`), the segment descriptor (`BM25SegMeta`), the block header
(`BM25BlockHdr`), the dictionary entry (`BM25DictEntry`), the pending-item
layout, the FOR/varint posting encoding, the sparsemap serialization
(`vendor/sm`), or the meaning of any persisted field. A change that only adds a
new C function, fixes a query/merge/build code path, or appends a field AFTER
the fixed `segs[]` array (which older readers ignore) is **not** a format
change and needs only the usual no-op `--OLD--NEW.sql`.

When a format change is unavoidable, do ALL of:

1. **Bump `version` in the metapage** (`BM25MetaPageData.version`, currently
   read by `bm25_check_meta`) so the code can tell old from new on sight.
2. **Read both formats.** Every reader/writer path must detect the metapage
   version and handle the old layout — either by interpreting the old bytes
   directly, or by transparently migrating a page/segment on first write. An
   old index opened by the new code must return correct results with NO manual
   step.
3. **Migrate lazily and in place** where possible (upgrade a segment/page when
   it is next merged/vacuumed), so the cost is amortized and no second full
   copy is needed. `fts_merge()`/`VACUUM` should converge an old-format index
   to the new format over time.
4. **Make it a minor release** (`X.Y+1.0`), and say plainly in the CHANGELOG
   and release notes: which format changed, that existing indexes keep working
   without a REINDEX, and (if applicable) that running `fts_merge()`/`VACUUM`
   completes the migration.
5. **Test the upgrade with a real old-format index**: build an index on the
   previous release, `ALTER EXTENSION pg_fts UPDATE`, load the new `.so`, and
   assert queries still return correct results and that a merge/vacuum migrates
   it cleanly. Add this as a TAP test so it is gated, not a one-off check.

The extension-SQL upgrade script (`pg_fts--OLD--NEW.sql`) only migrates SQL
objects; on-disk index bytes are migrated by the C code per the above, never by
the SQL script. A C-only format change therefore still ships a no-op
`--OLD--NEW.sql` PLUS the version-aware read/migrate code.

## What the tag triggers

- **Codeberg** (`.forgejo/workflows/release.yml`): build + `installcheck`, then
  `make dist` and attach `pg_fts-X.Y.Z.zip` to a Codeberg release.
- **GitHub mirror** (`.github/workflows/release.yml`): the same build + test,
  a GitHub Release with the zip, **and** the PGXN upload (done once, here — PGXN
  rejects a duplicate version, so only the GitHub side publishes).

The release artifact is a **source distribution** (`make dist` → a PGXN-layout
`pg_fts-X.Y.Z.zip` via `git archive`), not a compiled binary: a PGXS C
extension is built from source per PostgreSQL major / OS / arch by the user
(`make PG_CONFIG=...`). `.gitattributes export-ignore` keeps CI/dev/bench files
out of the zip.

## Required CI secrets

| Secret | Where | Purpose |
|--------|-------|---------|
| `PGXN_USER` / `PGXN_PASSWORD` | GitHub repo secrets | PGXN Manager upload (skipped if unset) |
| `RELEASE_TOKEN` | Codeberg repo secrets | create the Forgejo release (repo `write` scope) |

## Dependency-update automation

- **GitHub:** Dependabot (`.github/dependabot.yml`) opens weekly PRs bumping the
  GitHub Actions pins.
- **Codeberg:** `renovate.json` configures the Codeberg-hosted Renovate bot to
  do the equivalent for the `.forgejo/` (and `.github/`) workflow action pins.
  **TODO (maintainer):** Renovate must be enabled for the repo on Codeberg — add
  the Renovate app/bot under the repo (or org) settings so it reads
  `renovate.json`. Until then the config is inert but harmless.

## Manual PGXN upload (fallback)

If CI can't publish, upload by hand at <https://manager.pgxn.org/upload> (log
in, attach the `make dist` zip), or:

```sh
make dist PG_CONFIG=$(command -v pg_config)
curl --user "$PGXN_USER:$PGXN_PASSWORD" \
  -F "archive=@pg_fts-X.Y.Z.zip;type=application/zip" \
  https://manager.pgxn.org/upload
```
