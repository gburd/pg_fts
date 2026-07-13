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

echo "== capturing coverage =="
lcov --capture --directory . --output-file "$work/all.info" \
  --gcov-tool "$GCOV_TOOL" \
  --ignore-errors mismatch,source,gcov,unused,format,version,negative,inconsistent,corrupt \
  >/dev/null 2>&1 || true

# pg_fts-own sources (the gate) and vendor (reported only).
lcov --extract "$work/all.info" \
  "*/pg_fts_*.c" "*/pg_fts_*.h" "*/pg_fts.h" \
  --output-file "$work/own.info" \
  --ignore-errors unused,format,inconsistent >/dev/null 2>&1 || true
lcov --extract "$work/all.info" "*/vendor/sm.c" \
  --output-file "$work/vendor.info" \
  --ignore-errors unused,format,inconsistent >/dev/null 2>&1 || true

if [ "${COV_INCLUDE_VENDOR:-0}" = "1" ]; then
  lcov --extract "$work/all.info" \
    "*/pg_fts_*.c" "*/pg_fts_*.h" "*/pg_fts.h" "*/vendor/sm.c" \
    --output-file "$work/gate.info" \
    --ignore-errors unused,format,inconsistent >/dev/null 2>&1 || true
else
  cp "$work/own.info" "$work/gate.info"
fi

echo "== per-file (pg_fts-own; gate) =="
lcov --list "$work/own.info" --ignore-errors format,inconsistent 2>/dev/null || true
echo "== vendor/sm.c (reported, not gated) =="
lcov --summary "$work/vendor.info" --ignore-errors format,inconsistent 2>/dev/null \
  | grep -E 'lines' || echo "  (no vendor data)"

if [ -n "${COV_HTML:-}" ]; then
  genhtml "$work/gate.info" --output-directory "$COV_HTML" \
    --ignore-errors source,format,inconsistent >/dev/null 2>&1 || true
  echo "== HTML report written to $COV_HTML =="
fi

# --- gate ---------------------------------------------------------------------
pct="$(lcov --summary "$work/gate.info" --ignore-errors format,inconsistent 2>/dev/null \
  | sed -nE 's/.*lines\.+: ([0-9.]+)%.*/\1/p' | head -1)"
echo "== pg_fts-own line coverage: ${pct:-unknown}% (gate: >= ${COV_MIN}%) =="
if [ -z "$pct" ]; then
  echo "ERROR: could not determine coverage percentage" >&2
  exit 1
fi
awk -v p="$pct" -v m="$COV_MIN" 'BEGIN { exit !(p+0 >= m+0) }' || {
  echo "FAIL: coverage ${pct}% is below the ${COV_MIN}% gate" >&2
  exit 1
}
echo "PASS: coverage ${pct}% >= ${COV_MIN}%"
