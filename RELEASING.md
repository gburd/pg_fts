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
