# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Report privately to the maintainer via Codeberg: open a confidential/private
report on <https://codeberg.org/gregburd/pg_fts>, or contact the maintainer
directly.

<!-- TODO(maintainer): add a dedicated security contact address here (e.g. a
     PGP-encrypted email). Until then, private reports go through Codeberg. -->

Please include:

- the pg_fts version (`SELECT extversion FROM pg_extension WHERE extname = 'pg_fts';`)
  and the PostgreSQL major version,
- a description of the issue and its impact,
- a reproduction (SQL and/or a minimal C repro) if you have one.

You will get an acknowledgement, a fix or mitigation plan, and credit in the
release notes if you want it.

## Supported versions

Security fixes are made against the current **0.3.x** line. Older 0.2.x / 0.1.x
releases are not maintained; upgrade to the latest 0.3.x
(`ALTER EXTENSION pg_fts UPDATE`).

| Version | Supported |
|---------|-----------|
| 0.3.x   | Yes       |
| 0.2.x   | No        |
| 0.1.x   | No        |

## Security surface: `trusted = true`

pg_fts is a **trusted** extension (`trusted = true` in `pg_fts.control`). This
means a database user who is **not** a superuser but holds `CREATE` privilege on
the current database can run `CREATE EXTENSION pg_fts` — the same trust level
PostgreSQL grants to contrib modules like `pg_trgm` and `btree_gin`.

Implications a reviewer should keep in mind:

- Every C function installed by the extension runs with the privileges of the
  role that *invokes* it, but the extension objects are created by a superuser-
  equivalent bootstrap during `CREATE EXTENSION`. A trusted extension must
  therefore not expose a way for an unprivileged installer/caller to escalate
  privileges or read/write outside their own authorization.
- The extension's SQL functions operate only on `ftsdoc`/`ftsquery` values, the
  `fts` index, and the caller's own tables (via `regclass` arguments that are
  permission-checked by the normal catalog/ACL path). It adds no
  filesystem, network, or `SECURITY DEFINER` surface.
- All input at trust boundaries (`ftsdoc_in`, `ftsdoc_recv`, `ftsquery_in`,
  `ftsquery_recv`) is validated before use, so a hostile `COPY`/`pg_dump`
  restore of a stored `ftsdoc`/`ftsquery` column cannot corrupt memory.

If you believe the trusted marking enables an escalation that a trusted contrib
extension should not, that is exactly the kind of report we want — see above.
