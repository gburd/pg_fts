#!/usr/bin/env bash
# Ground-truth ranked-parity gate for pg_fts.
#
# For each query band, compare the index KNN top-k
#   (WHERE d @@@ q ORDER BY d <=> q LIMIT k)
# against the brute-force exact BM25 top-k (seqscan + fts_bm25, ORDER BY score).
# The two lists are fetched as SEPARATE queries (a single query holding both a
# KNN subquery and an exact-sort subquery lets the planner share/rewrite the
# scan and pick different rows -- a harness artifact, not an engine result).
#
# A genuine miss = an index-returned doc whose exact score is strictly below the
# exact k-th score (the index admitted a doc outside the true top-k band).  Score
# ties are fine: any doc scoring >= the exact k-th score is a valid top-k member.
#
# This is the kill signal for any phase that changes scoring math (e.g. Phase 2
# doclen quantization): run before AND after; require genuine_misses=0 (exact) or
# <= the documented quantization bound (lossy).
#
# Usage: parity_check.sh <dsn> <table> <ftsdoc_col> <fts_index> [terms...]
set -euo pipefail

DSN="${1:?dsn}"; TBL="${2:?table}"; COL="${3:?ftsdoc col}"; IDX="${4:?fts index}"
shift 4
TERMS=("$@")
[ ${#TERMS[@]} -eq 0 ] && TERMS=("slovakia" "hungary" "year" "slovakia & hungary")

# Quantization tolerance.  The v4 doclen sidecar stores a 1-byte quantized
# length, so BM25 scores near a tie boundary can differ from the exact (true
# doclen) score by a bounded amount -- a doc scoring within TOL of the exact
# k-th score is an equivalent top-k member (Lucene/Tantivy fieldnorm behavior),
# NOT a recall error.  Measured bound on the 2M rig: worst case ~0.2% below the
# cutoff.  TOL is a fraction (0.01 = 1%); set PARITY_TOL=0 for exact (v3) checks.
TOL="${PARITY_TOL:-0.01}"

Q() { psql "$DSN" -X -q -t -A -c "$1"; }

read -r NDOCS AVGDL < <(psql "$DSN" -X -q -t -A -F' ' -c \
  "SELECT count(*), avg(ftsdoc_length($COL))::float8 FROM $TBL")

fail=0
for term in "${TERMS[@]}"; do
  for k in 10 100; do
    QQ="to_ftsquery('english', '${term}')"
    SC="fts_bm25(t.$COL, $QQ, $NDOCS::float8, $AVGDL::float8, fts_index_df('$IDX', $QQ))"
    # exact k-th score (cutoff for the true top-k band)
    kth=$(Q "SELECT min(sc) FROM (SELECT $SC AS sc FROM $TBL t
             WHERE t.$COL @@@ $QQ ORDER BY sc DESC LIMIT $k) z")
    # A genuine miss is an index-returned doc whose exact score is below the
    # exact k-th score by MORE than the quantization tolerance TOL (a fraction).
    # Within TOL the doc is an equivalent top-k member (v4 doclen quantization),
    # not a recall error.
    gm=$(Q "WITH idx AS (SELECT $SC AS sc FROM $TBL t
              WHERE t.$COL @@@ $QQ ORDER BY t.$COL <=> $QQ LIMIT $k)
            SELECT count(*) FROM idx WHERE sc < ${kth} * (1.0 - ${TOL}) - 1e-6")
    gm=$(echo "$gm" | tr -d '[:space:]')
    if [ "${gm:-x}" = "0" ]; then
      echo "PASS  term='${term}' k=${k}  genuine_misses=0"
    else
      echo "FAIL  term='${term}' k=${k}  genuine_misses=${gm}  (exact kth=${kth})"
      fail=1
    fi
  done
done

if [ "$fail" = "0" ]; then echo "== PARITY PASS =="; else echo "== PARITY FAIL =="; exit 1; fi
