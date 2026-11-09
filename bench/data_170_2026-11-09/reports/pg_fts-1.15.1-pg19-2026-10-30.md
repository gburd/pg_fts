# pg_fts 1.15.1 does not build against PostgreSQL 19 (RC1)

pg.ddx.io's move to PostgreSQL 19 is blocked on this: every other extension we run builds on
19rc1 (pg_tre 4.5.3, pg_turbovec 2.15.0, pg_mentat 1.18.0, pg_cron 1.6.8).

## Errors (clang 21, PostgreSQL REL_19_RC1 0b8bff04, nixpkgs builder)

```
pg_fts_shdoclen.c:764:3: error: call to undeclared function 'tuplestore_putvalues'
pg_fts_customscan.c:158:51: error: incomplete definition of type 'const struct IndexAmRoutine'
pg_fts_customscan.c:289:70: error: too few arguments to function call, expected 5, have 4
pg_fts_customscan.c:290:69: error: too few arguments to function call, expected 5, have 4
pg_fts_customscan.c:902:15: error: incompatible function pointer types assigning to 'planner_hook_type'
```

## Causes

1. PostgreSQL 19 no longer includes `utils/tuplestore.h` from `nodes/execnodes.h` (18.6 does),
   so `pg_fts_shdoclen.c` (1.10.0) loses `tuplestore_putvalues()`.
2. `IndexAmRoutine` is complete only with `access/amapi.h`, which 19 no longer pulls in through
   `access/genam.h`; `pg_fts_customscan.c` dereferences `rd_indam`.
3. The planner hook gained an argument in 19 (c83ac02ec73): `planner_hook_type` and
   `standard_planner()` take a trailing `ExplainState *es`.

All three were in our 2026-10-17 report against 1.14.1 (as 5 errors in 2 files); the
include in (1) has since moved to the new file.

## Patch (attached: pg_fts-1.15.1-pg19-2026-10-30.patch, 2 files, +13)

- `#include "utils/tuplestore.h"` in pg_fts_shdoclen.c;
- `#include "access/amapi.h"` in pg_fts_customscan.c;
- `fts_planner()` takes and passes `ExplainState *es` under `#if PG_VERSION_NUM >= 190000`.

Verified: with the patch, 1.15.1 builds against 19rc1 and still builds against 18.6. Not
run: the regression suite on 19. We did not deploy a patched build (we do not fork pg_fts).

## Ask

A release that builds on 19 (and makes the 19 CI leg required: `continue-on-error:
${{ matrix.pg == 19 }}` is what lets this through). PostgreSQL 19.0 GA is due 2026-11-19.
