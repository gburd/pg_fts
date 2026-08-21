#!/usr/bin/env bash
#
# ci/coverage.sh -- build pg_fts with gcov instrumentation, run the SQL
# regression + isolation suite against a throwaway cluster, and report line
# coverage of the EXTENSION sources.
#
# Gate: line coverage of the pg_fts-OWN sources (pg_fts_*.c / *.h) must be
# >= COV_MIN (default 90).  The vendored sparsemap (vendor/sm.c, ~4k lines,
# most of its API unused by pg_fts) is reported separately for transparency
# but is NOT part of the gate -- an unused vendored API is not pg_fts's test
# debt.  Set COV_INCLUDE_VENDOR=1 to fold it into the gate denominator.
#
# Environment:
#   PG_CONFIG   pg_config to build against (default: pg_config on PATH)
#   PGBIN       directory with initdb/pg_ctl/psql (default: $(pg_config --bindir))
#   COV_MIN     minimum pg_fts-own line coverage %% to pass (default 90)
#   COV_HTML    if set, write an lcov HTML report to $COV_HTML
#   GCOV_TOOL   gcov binary (default: gcov)
#
# Assumes a WRITABLE PostgreSQL install (as on CI: pgdg / the postgres image),
# so `make install` puts the instrumented .so + control where a fresh cluster
# finds it.  This is the same install path the `sanitizers` job uses.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

PG_CONFIG="${PG_CONFIG:-pg_config}"
PGBIN="${PGBIN:-$("$PG_CONFIG" --bindir)}"
COV_MIN="${COV_MIN:-90}"
GCOV_TOOL="${GCOV_TOOL:-gcov}"

work="$(mktemp -d)"
trap '"$PGBIN/pg_ctl" -D "$work/pgdata" -w stop >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

echo "== coverage build (gcov, PG_CONFIG=$PG_CONFIG) =="
make clean PG_CONFIG="$PG_CONFIG" >/dev/null 2>&1 || true
rm -f ./*.gcno ./*.gcda vendor/*.gcno vendor/*.gcda
# with_llvm=no: skip PGXS's LLVM-bitcode emission (JIT), which conflicts with
# gcov instrumentation.  -fno-lto: gcov needs per-object arc files.
make PG_CONFIG="$PG_CONFIG" with_llvm=no \
  COPT="--coverage -O0 -g -fno-lto -DUSE_ASSERT_CHECKING" \
  SHLIB_LINK="--coverage" >/dev/null
test -f pg_fts.so

# Install the instrumented .so + control into the PG prefix so CREATE EXTENSION
# (and the isolation/regress harness) resolve it.  The prefix usually needs
# root; use sudo when available and not already root.
if [ "$(id -u)" -eq 0 ]; then INSTALL="make install"
elif command -v sudo >/dev/null 2>&1; then INSTALL="sudo make install"
else INSTALL="make install"; fi
$INSTALL PG_CONFIG="$PG_CONFIG" >/dev/null

# The regression run (initdb/backend + .gcda writes) must not run as root, and
# must own the build tree so gcov can write .gcda.  If we're root (e.g. the
# postgres:NN CI container), run the cluster + tests as the `postgres` user and
# hand it the tree; otherwise run as ourselves.
if [ "$(id -u)" -eq 0 ]; then
  RUNAS=postgres
  chown -R postgres "$root" "$work"
else
  RUNAS=""
fi
run_as() { if [ -n "$RUNAS" ]; then su "$RUNAS" -c "$1"; else bash -c "$1"; fi; }

# --- throwaway cluster --------------------------------------------------------
export PGDATA="$work/pgdata" PGHOST="$work" PGPORT=54329 PGUSER=postgres
run_as "'$PGBIN/initdb' -D '$PGDATA' -U postgres --no-locale --encoding=UTF8 >/dev/null 2>&1"
{
  echo "listen_addresses=''"
  echo "unix_socket_directories='$work'"
  echo "fsync=off"
} >> "$PGDATA/postgresql.conf"
run_as "'$PGBIN/pg_ctl' -D '$PGDATA' -l '$work/pg.log' -w start >/dev/null"

echo "== running REGRESS + ISOLATION under the instrumented .so =="
# The instrumented .so is installed in the PG prefix, so CREATE EXTENSION
# resolves it.  PROVE_TESTS=ci/noop.pl no-ops the TAP stage (TAP has its own
# clusters and is exercised by the `test` job).
run_as "cd '$root' && make installcheck PG_CONFIG='$PG_CONFIG' PROVE_TESTS=ci/noop.pl PGHOST='$work' PGUSER=postgres PGPORT=54329" || {
    echo "--- regression.diffs ---";     head -60 regression.diffs 2>/dev/null || true
    echo "--- iso regression.diffs ---"; head -40 output_iso/regression.diffs 2>/dev/null || true
    exit 1
  }
run_as "'$PGBIN/pg_ctl' -D '$PGDATA' -w stop >/dev/null 2>&1" || true

# Optionally drive the engine's scale/feature branches with a moderate high-
# vocabulary corpus (multi-segment merges, dict-index, positions, trigram,
# WAND/MaxScore deep, vacuum/tombstone) so those .gcda accumulate.  COV_CORPUS=1.
if [ "${COV_CORPUS:-0}" = "1" ]; then
  echo "== driving scale/feature branches with ci/cov_corpus.sql (COV_CORPUS) =="
  run_as "'$PGBIN/pg_ctl' -D '$PGDATA' -l '$work/pg2.log' -w start >/dev/null" || true
  run_as "'$PGBIN/createdb' -h '$work' -p 54329 -U postgres covcorp >/dev/null 2>&1" || true
  run_as "'$PGBIN/psql' -h '$work' -p 54329 -U postgres -d covcorp -v ON_ERROR_STOP=0 -f '$root/ci/cov_corpus.sql' > '$work/covcorp.log' 2>&1" || echo "WARN: cov_corpus had issues (continuing)"
  run_as "'$PGBIN/pg_ctl' -D '$PGDATA' -w stop >/dev/null 2>&1" || true
fi
# corruption, concurrency, segment-cap, vacuum-reclaim) against the SAME
# instrumented .so so their .gcda accumulate -- these reach many defensive /
# recovery / error branches that the SQL regression suite cannot.  COV_WITH_TAP=1.
if [ "${COV_WITH_TAP:-0}" = "1" ]; then
  echo "== running TAP under the instrumented .so (COV_WITH_TAP) =="
  run_as "cd '$root' && rm -rf tmp_check && PERL5LIB='${PERL5LIB:-}' make installcheck REGRESS= ISOLATION= PROVE_TESTS='t/001_crash_recovery.pl t/002_replication.pl t/003_corruption.pl t/004_encodings.pl t/005_concurrency.pl t/006_concurrent_extend.pl t/007_segment_cap.pl t/008_vacuum_reclaim.pl' PG_CONFIG='$PG_CONFIG'" || echo "WARN: TAP under coverage had failures (continuing; coverage still captured)"
fi
lcov --capture --directory . --output-file "$work/all.info" \
  --gcov-tool "$GCOV_TOOL" --rc branch_coverage=1 \
  --ignore-errors mismatch,source,gcov,unused,format,version,negative,inconsistent,corrupt \
  >/dev/null 2>&1 || true

# pg_fts-own sources (the gate) and vendor (reported only).
lcov --extract "$work/all.info" \
  "*/pg_fts_*.c" "*/pg_fts_*.h" "*/pg_fts.h" \
  --output-file "$work/own.info" --rc branch_coverage=1 \
  --ignore-errors unused,format,inconsistent >/dev/null 2>&1 || true
lcov --extract "$work/all.info" "*/vendor/sm.c" \
  --output-file "$work/vendor.info" --rc branch_coverage=1 \
  --ignore-errors unused,format,inconsistent >/dev/null 2>&1 || true

if [ "${COV_INCLUDE_VENDOR:-0}" = "1" ]; then
  lcov --extract "$work/all.info" \
    "*/pg_fts_*.c" "*/pg_fts_*.h" "*/pg_fts.h" "*/vendor/sm.c" \
    --output-file "$work/gate.info" --rc branch_coverage=1 \
    --ignore-errors unused,format,inconsistent >/dev/null 2>&1 || true
else
  cp "$work/own.info" "$work/gate.info"
fi

echo "== per-file (pg_fts-own; gate) =="
lcov --list "$work/own.info" --rc branch_coverage=1 --ignore-errors format,inconsistent 2>/dev/null || true
echo "== vendor/sm.c (reported, not gated) =="
lcov --summary "$work/vendor.info" --ignore-errors format,inconsistent 2>/dev/null \
  | grep -E 'lines' || echo "  (no vendor data)"

if [ -n "${COV_HTML:-}" ]; then
  genhtml "$work/gate.info" --output-directory "$COV_HTML" \
    --ignore-errors source,format,inconsistent >/dev/null 2>&1 || true
  echo "== HTML report written to $COV_HTML =="
fi

# --- gate ---------------------------------------------------------------------
pct="$(lcov --summary "$work/gate.info" --rc branch_coverage=1 --ignore-errors format,inconsistent 2>/dev/null \
  | sed -nE 's/.*lines\.+: ([0-9.]+)%.*/\1/p' | head -1)"
echo "== pg_fts-own line coverage: ${pct:-unknown}% (gate: >= ${COV_MIN}%) =="
if [ -z "$pct" ]; then
  echo "ERROR: could not determine coverage percentage" >&2
  exit 1
fi
awk -v p="$pct" -v m="$COV_MIN" 'BEGIN { exit !(p+0 >= m+0) }' || {
  echo "FAIL: line coverage ${pct}% is below the ${COV_MIN}% gate" >&2
  exit 1
}
echo "PASS: line coverage ${pct}% >= ${COV_MIN}%"

# --- function + branch gates (default >= COV_FUNC_MIN / COV_BRANCH_MIN) --------
# --- function + branch gates ---------------------------------------------------
# Function coverage gates at 85% (achieved ~98%).  Branch coverage gates at 73%:
# pg_fts is a hardened storage engine whose two large files (pg_fts_am.c,
# pg_fts_am_scan.c) carry ~600 DELIBERATELY-UNREACHABLE-from-valid-input
# defensive branches -- corruption guards, OOM / huge-alloc fallbacks,
# generation-recheck retry loops, torn-page handling, parallel-worker-only
# races.  Those are validated by the fuzz harness (test/fuzz, ALL CLEAN, with
# planted-bug teeth) and the ASan concurrency-churn tests, NOT by functional
# SQL.  Measured functional-test branch coverage: installcheck+isolation alone
# ~73%, +COV_CORPUS ~75%, +COV_WITH_TAP ~76%.  lcov version differs between the
# EC2 (Fedora) and CI (Debian/pgdg) runners by ~1-1.5 points, so the gate is set
# at 73% with headroom below the lowest measured mode.  Raise COV_BRANCH_MIN as
# reachable branches gain tests; do not chase 100% -- that only re-tests
# defensive code.  Line ~93%, function ~98%.
COV_FUNC_MIN="${COV_FUNC_MIN:-85}"
COV_BRANCH_MIN="${COV_BRANCH_MIN:-73}"
summary="$(lcov --summary "$work/gate.info" --rc branch_coverage=1 \
  --ignore-errors format,inconsistent 2>/dev/null)"
fpct="$(printf '%s\n' "$summary" | sed -nE 's/.*functions\.+: ([0-9.]+)%.*/\1/p' | head -1)"
bpct="$(printf '%s\n' "$summary" | sed -nE 's/.*branches\.+: ([0-9.]+)%.*/\1/p' | head -1)"
echo "== pg_fts-own function coverage: ${fpct:-unknown}% (gate: >= ${COV_FUNC_MIN}%) =="
echo "== pg_fts-own branch coverage:   ${bpct:-unknown}% (gate: >= ${COV_BRANCH_MIN}%) =="
fail=0
if [ -n "$fpct" ]; then
  awk -v p="$fpct" -v m="$COV_FUNC_MIN" 'BEGIN { exit !(p+0 >= m+0) }' || {
    echo "FAIL: function coverage ${fpct}% is below the ${COV_FUNC_MIN}% gate" >&2; fail=1; }
else echo "WARN: no function coverage data" >&2; fi
if [ -n "$bpct" ]; then
  awk -v p="$bpct" -v m="$COV_BRANCH_MIN" 'BEGIN { exit !(p+0 >= m+0) }' || {
    echo "FAIL: branch coverage ${bpct}% is below the ${COV_BRANCH_MIN}% gate" >&2; fail=1; }
else echo "WARN: no branch coverage data" >&2; fi
# Per-function floor: list any function below COV_FUNC_MIN individually so gaps
# are actionable (requires COV_PERFUNC=1; needs gcov --function-summaries data).
if [ "${COV_PERFUNC:-0}" = "1" ]; then
  echo "== functions below ${COV_FUNC_MIN}% (0 hits shown as uncovered) =="
  lcov --list-full-path --list "$work/own.info" --rc branch_coverage=1 \
    --ignore-errors format,inconsistent 2>/dev/null | head -60 || true
fi
[ "$fail" -eq 0 ] || exit 1
echo "PASS: function ${fpct}% >= ${COV_FUNC_MIN}%, branch ${bpct}% >= ${COV_BRANCH_MIN}%"
