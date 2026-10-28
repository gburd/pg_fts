# 1.14.3 final gate

The code tree is **60aa460**.  The release commit after it changes only bench/ and
docs.  The host was EC2 c6id.8xlarge, Debian 13, PostgreSQL 17.10 and 18.6 built from
source.  Each stage asserts green, and every tarball is a full `git ls-files` tree;
`git archive` would drop `ci/`, `test/` and `.github/`.

| stage (log in `gate_final/`) | result |
|---|---|
| installcheck PG17 / PG18 (27 regress + 4 isolation) | 31 ok / 31 ok |
| query_binary PG17 / PG18 | 49 passed / 49 passed |
| TAP PG17 / PG18 (10 files incl. `t/013_ranked_flush_race.pl`) | PASS / PASS |
| `ci/check-alloc.sh`, `make check-ascii`, `test/fuzz/run.sh` | rc=0, rc=0, ALL CLEAN |
| t/012 reruns x3 (PG17) | PASS x3 |
| upgrade 1.14.2 -> 1.14.3 in place, PG17 / PG18; 70 sources reach 1.14.3 | UPGRADE OK x2 |
| ASan PG17 smoke (`asan143.log`) | all checks passed; 0 AddressSanitizer lines |
| per-commit installcheck, 9 code commits (PG18) | all rc=0, 0 not-ok |
| nix flake: installcheck-pg17/18, tap-pg17/18 (`nix_summary.txt`) | rc=0; t/013 ok in both TAP |
| nix installcheck-pg17 `--rebuild` x2 | PASS x2 |
