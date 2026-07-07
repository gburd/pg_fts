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
2. Tag and push (Codeberg is `origin`; it auto-mirrors to the GitHub mirror):
   ```sh
   git tag -a vX.Y.Z -m "pg_fts X.Y.Z — <summary>"
   git push origin vX.Y.Z
   ```

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

## Manual PGXN upload (fallback)

If CI can't publish, upload by hand at <https://manager.pgxn.org/upload> (log
in, attach the `make dist` zip), or:

```sh
make dist PG_CONFIG=$(command -v pg_config)
curl --user "$PGXN_USER:$PGXN_PASSWORD" \
  -F "archive=@pg_fts-X.Y.Z.zip;type=application/zip" \
  https://manager.pgxn.org/upload
```
