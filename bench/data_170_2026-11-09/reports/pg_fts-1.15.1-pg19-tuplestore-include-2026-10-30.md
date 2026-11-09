# pg_fts 1.15.1 does not build against PostgreSQL 19 (RC1): missing utils/tuplestore.h

```
pg_fts_shdoclen.c:764:3: error: call to undeclared function 'tuplestore_putvalues';
ISO C99 and later do not support implicit function declarations
```

Cause: PostgreSQL 19 no longer includes `utils/tuplestore.h` from `nodes/execnodes.h`
(18.6 does; 19rc1's only remaining includer is `executor/tstoreReceiver.h`).
`pg_fts_shdoclen.c` calls `tuplestore_putvalues()` but includes only `funcapi.h`, so it
compiled on 18 through the transitive include and fails on 19. This is the same class as the
`tuplestore.h` item in our 2026-10-17 report (pg_fts_am.c then), now in the file 1.10.0 added.

Fix (one line, attached as pg_fts-1.15.1-pg19-tuplestore-include-2026-10-30.patch):
`#include "utils/tuplestore.h"` after `funcapi.h` in pg_fts_shdoclen.c.

Built against: PostgreSQL 19rc1 (REL_19_RC1, 0b8bff04), clang 21, nixpkgs builder.
pg_tre 4.5.3, pg_turbovec 2.15.0, pg_mentat 1.18.0 and pg_cron 1.6.8 all build on the same
19rc1. pg_fts is the only PG19 build failure, and it blocks pg.ddx.io's move to 19.

Suggestion: make the 19 leg of CI required (`continue-on-error: ${{ matrix.pg == 19 }}`
hides exactly this), now that 19 is at RC.
