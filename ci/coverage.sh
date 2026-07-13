#!/usr/bin/env bash
#
# ci/coverage.sh -- build pg_fts with gcov instrumentation, run the full test
# set (SQL regression + isolation, then merge the standalone fuzz + hegel
# coverage if present), and report line coverage of the EXTENSION sources.
#
# Gate: line coverage of the pg_fts-OWN sources (pg_fts_*.c / *.h) must be
# >= COV_MIN (default 90).  The vendored sparsemap (vendor/sm.c, ~4k lines,
# most of its API unused by pg_fts) is reported separately for transparency
# but is NOT part of the gate -- an unused vendored API is not pg_fts's test
# debt.  Set COV_INCLUDE_VENDOR=1 to fold it into the gate denominator.
#
# Environment:
#   PG_CONFIG   pg_config to build against (default: pg_config on PATH)
#   COV_MIN     minimum pg_fts-own line coverage %% to pass (default 90)
#   PGBIN       directory with initdb/pg_ctl/psql (default: $(pg_config --bindir))
#   COV_HTML    if set, write an lcov HTML report to $COV_HTML
#   GCOV_TOOL   gcov binary (default: gcov; a wrapper for llvm-cov gcov works too)
#
# This mirrors how the sanitizer/fuzz jobs are wired: a single self-contained
# script both CIs invoke, so .github and .forgejo stay in lockstep.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

PG_CONFIG="${PG_CONFIG:-pg_config}"
PGBIN="${PGBIN:-$("$PG_CONFIG" --bindir)}"
COV_MIN="${COV_MIN:-90}"
GCOV_TOOL="${GCOV_TOOL:-gcov}"
PGMAJOR="$("$PG_CONFIG" --version | sed -E 's/[^0-9]*([0-9]+).*/\1/')"

work="$(mktemp -d)"
trap 'pg_ctl -D "$work/pgdata" -w stop >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

echo "== coverage build (gcov, PG $PGMAJOR, PG_CONFIG=$PG_CONFIG) =="
make clean PG_CONFIG="$PG_CONFIG" >/dev/null 2>&1 || true
rm -f ./*.gcno ./*.gcda vendor/*.gcno vendor/*.gcda
# with_llvm=no: skip PGXS's LLVM-bitcode emission (JIT), which conflicts with
# gcov instrumentation.  -fno-lto: gcov needs per-object arc files.
make PG_CONFIG="$PG_CONFIG" with_llvm=no \
  COPT="--coverage -O0 -g -fno-lto -DUSE_ASSERT_CHECKING" \
  SHLIB_LINK="--coverage" >/dev/null
test -f pg_fts.so

# --- install into a writable extension dir + start a throwaway cluster --------
extdir="$work/ext"; libdir="$work/lib"
mkdir -p "$extdir/extension" "$libdir"
cp pg_fts.so "$libdir/"
cp pg_fts.control pg_fts--*.sql "$extdir/extension/"
sed -i "s|\$libdir/pg_fts|$libdir/pg_fts|" "$extdir/extension/pg_fts.control"

export PGDATA="$work/pgdata" PGHOST="$work" PGPORT=54329 PGUSER=postgres
"$PGBIN/initdb" -U postgres --no-locale --encoding=UTF8 >/dev/null 2>&1

# PG 18+ has extension_control_path; PG 17 does not.  On PG 17, symlink the
# system sharedir's extension dir alongside ours so contrib (fuzzystrmatch) is
# still resolvable, and put our control there via a writable copy of sharedir.
if [ "$PGMAJOR" -ge 18 ]; then
  {
    echo "listen_addresses=''"
    echo "unix_socket_directories='$work'"
    echo "extension_control_path='\$system:$extdir'"
    echo "dynamic_library_path='\$libdir:$libdir'"
    echo "fsync=off"
  } >> "$PGDATA/postgresql.conf"
else
  # PG 17: no control-path GUC.  Make a writable clone of the sharedir's
  # extension directory (symlinks to the read-only originals) + our files, and
  # point PGXS installcheck's control search at it via a wrapped sharedir.
  sysshare="$("$PG_CONFIG" --sharedir)"
  mkdir -p "$work/share/extension"
  # symlink every system extension control/sql so contrib stays available
  if [ -d "$sysshare/extension" ]; then
    ln -s "$sysshare/extension/"* "$work/share/extension/" 2>/dev/null || true
  fi
  # our (coverage) control + sql win over any symlinked copy
  cp -f pg_fts.control pg_fts--*.sql "$work/share/extension/"
  sed -i "s|\$libdir/pg_fts|$libdir/pg_fts|" "$work/share/extension/pg_fts.control"
  {
    echo "listen_addresses=''"
    echo "unix_socket_directories='$work'"
    echo "dynamic_library_path='\$libdir:$libdir'"
    echo "fsync=off"
  } >> "$PGDATA/postgresql.conf"
fi

"$PGBIN/pg_ctl" -D "$PGDATA" -l "$work/pg.log" -w start >/dev/null

echo "== running REGRESS + ISOLATION under the instrumented .so =="
# PG 17: point PGXS at the wrapped sharedir so CREATE EXTENSION finds our copy.
extra=()
[ "$PGMAJOR" -lt 18 ] && extra=(EXTRA_REGRESS_OPTS="--extra-install=" )
make installcheck PG_CONFIG="$PG_CONFIG" PROVE_TESTS=ci/noop.pl \
  PGHOST="$work" PGUSER=postgres PGPORT=54329 \
  ${PGMAJOR:+} 2>&1 | tail -12 || {
    echo "--- regression.diffs ---";     head -60 regression.diffs 2>/dev/null || true
    echo "--- iso regression.diffs ---"; head -40 output_iso/regression.diffs 2>/dev/null || true
    "$PGBIN/pg_ctl" -D "$PGDATA" -w stop >/dev/null 2>&1 || true
    exit 1
  }
"$PGBIN/pg_ctl" -D "$PGDATA" -w stop >/dev/null 2>&1 || true

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
  cp "$work/all.info" "$work/gate.info"
  lcov --extract "$work/gate.info" \
    "*/pg_fts_*.c" "*/pg_fts_*.h" "*/pg_fts.h" "*/vendor/sm.c" \
    --output-file "$work/gate.info.2" \
    --ignore-errors unused,format,inconsistent >/dev/null 2>&1 || true
  mv "$work/gate.info.2" "$work/gate.info"
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

# --- extract the gated % and enforce the threshold ---------------------------
pct="$(lcov --summary "$work/gate.info" --ignore-errors format,inconsistent 2>/dev/null \
  | sed -nE 's/.*lines\.+: ([0-9.]+)%.*/\1/p' | head -1)"
: "${pct:=0}"
echo ""
echo "=================================================================="
printf '  pg_fts extension line coverage (gate): %s%%  (min %s%%)\n' "$pct" "$COV_MIN"
echo "=================================================================="

awk -v p="$pct" -v m="$COV_MIN" 'BEGIN{ exit !(p+0 >= m+0) }' || {
  echo "FAIL: line coverage $pct% < required $COV_MIN%"
  exit 1
}
echo "PASS: line coverage $pct% >= $COV_MIN%"
