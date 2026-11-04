#!/usr/bin/env bash
#
# test/cbmc/run.sh -- run every pg_fts CBMC harness and report PASS/FAIL.
#
# Each entry point proves a property of shipped pg_fts code (or a VERBATIM
# copy of it, checked by check_verbatim.py) over ALL inputs within its bound;
# see README.md.  Exit non-zero if a harness that must verify does not, if a
# TEETH build (a planted bug) is NOT caught, or if a copy has drifted.
#
#   bash test/cbmc/run.sh               # all harnesses
#   bash test/cbmc/run.sh codec bound   # only harness files matching
#
# Needs cbmc (validated with 6.6.0 and 6.9.0) and python3.  No harness uses
# concurrent pointers, so CBMC 6.x's "pointer handling for concurrency is
# unsound" abort (see libxtc's test/cbmc) does not apply.
set -u
cd "$(dirname "$0")"
CBMC=${CBMC:-cbmc}
TIMEOUT=${CBMC_TIMEOUT:-1800}
FAIL=0
ONLY="$*"

if ! command -v "$CBMC" >/dev/null 2>&1; then
	echo "cbmc not on PATH" >&2
	exit 2
fi
echo "cbmc $("$CBMC" --version | head -1)"

# The memory-safety core plus integer UB.  Unsigned wrap is defined C and the
# codecs rely on it, so --unsigned-overflow-check is not global.
COMMON="--bounds-check --pointer-check --signed-overflow-check --undefined-shift-check --div-by-zero-check --drop-unused-functions"

want() {
	[ -z "$ONLY" ] && return 0
	local w
	for w in $ONLY; do
		case "$1" in *"$w"*) return 0 ;; esac
	done
	return 1
}

# expect <PASS|FAIL> <label> <file> <function> <extra cbmc args...>
expect() {
	local exp=$1 label=$2 file=$3 func=$4
	shift 4
	want "$file" || return 0
	local tmp verdict secs
	tmp=$(mktemp)
	SECONDS=0
	timeout "$TIMEOUT" "$CBMC" "$file" --function "$func" $COMMON "$@" >"$tmp" 2>&1
	secs=$SECONDS
	if grep -q "^VERIFICATION SUCCESSFUL" "$tmp"; then
		verdict=PASS
	elif grep -q "^VERIFICATION FAILED" "$tmp"; then
		verdict=FAIL
	else
		verdict=ERROR
	fi
	if [ "$verdict" = "$exp" ]; then
		printf 'ok    %-34s %s as expected (%ss)\n' "$label" "$verdict" "$secs"
		[ "$exp" = FAIL ] && grep ": FAILURE" "$tmp" | head -2 | sed 's/^/        caught: /'
	else
		printf 'BAD   %-34s expected %s, got %s (%ss)\n' "$label" "$exp" "$verdict" "$secs"
		grep -E ": FAILURE|^\*\*\*\*|error|Unknown option" "$tmp" | head -8 | sed 's/^/        /'
		[ "$verdict" = ERROR ] && tail -5 "$tmp" | sed 's/^/        /'
		FAIL=1
	fi
	rm -f "$tmp"
}

# 0. transcriptions still match the source
if [ -z "$ONLY" ]; then
	if python3 check_verbatim.py; then :; else FAIL=1; fi
fi

# 5. codecs (pg_fts_for.h).  n is concrete per run (a symbolic n ran a 30 GB
#    host out of memory); the bitwidth loop needs 65 iterations, the rest <= 10.
FORU="--unwind 12 --unwindset bm25_bitwidth.0:66 --unwinding-assertions"
for n in 1 2 3 8; do
	expect PASS "for n=$n"       codec_harness.c harness_for     -DFOR_N=$n $FORU
	expect PASS "for_any n=$n"   codec_harness.c harness_for_any -DFOR_N=$n $FORU
done
for w in 65 128 255; do
	expect PASS "for_corrupt w=$w" codec_harness.c harness_for_corrupt_width -DFOR_N=3 -DCORRUPT_W=$w $FORU
done
expect PASS doclen       codec_harness.c harness_doclen
expect PASS doclen_total codec_harness.c harness_doclen_total
expect FAIL "for TEETH (short buffer)" codec_harness.c harness_for -DFOR_N=2 -DTEETH_FOR $FORU
expect FAIL "doclen TEETH (exact)"     codec_harness.c harness_doclen -DTEETH_DOCLEN

# 3. guards on untrusted page bytes.  The page is a 96-byte nondeterministic
#    array; --pointer-overflow-check flags a pointer formed past it from an
#    on-disk integer (AGENTS.md rule 16).
ODU="--unwind 12 --unwindset nondet_page.0:100 --unwinding-assertions --pointer-overflow-check --object-bits 12"
expect PASS page_data_end   ondisk_harness.c harness_page_data_end $ODU
expect PASS docvalid        ondisk_harness.c harness_docvalid      $ODU --unwindset harness_docvalid.0:100
expect PASS dict_walk       ondisk_harness.c harness_dict_walk     $ODU
expect PASS block_decode    ondisk_harness.c harness_block_decode  $ODU
expect PASS load_block      ondisk_harness.c harness_load_block    $ODU
expect PASS doclen_block    ondisk_harness.c harness_doclen_block  $ODU
expect FAIL "page_data_end TEETH (pd_lower)"   ondisk_harness.c harness_page_data_end -DTEETH_PDLOWER $ODU
expect FAIL "block_decode TEETH (0.3.4 clamp)" ondisk_harness.c harness_block_decode -DTEETH_ONESIDED $ODU
expect FAIL "block_decode TEETH (1.15.2 cols)"  ondisk_harness.c harness_block_decode -DTEETH_DECODE_COLS $ODU
expect FAIL "dict_walk TEETH (1.15.2 ptr)"     ondisk_harness.c harness_dict_walk -DTEETH_DICT_PTR $ODU
expect FAIL "load_block TEETH (1.15.2)"        ondisk_harness.c harness_load_block -DTEETH_LOADBLOCK $ODU
expect FAIL "doclen_block TEETH (1.15.2)"      ondisk_harness.c harness_doclen_block -DTEETH_DOCLEN_GAPS $ODU

# 2. BM25 block bounds >= every covered score, in IEEE doubles.  CBMC
#    bit-blasts every double operation, so one ulp below is a counterexample.  With tf,
# |D| and the block symbolic and (avgdl, idf) fixed, minisat had not finished
# one shape in 90 minutes (Debian 13's cbmc 6.6.0, 256 GB host); they run
# only with CBMC_FP=1.  The exhaustive native sweep below covers the same
# properties over 2,000 corpus shapes in about 30 s, and 11.1 billion cases at
# 10,000 shapes (bound_exhaustive.c 10000) found no violation.
if [ "${CBMC_FP:-0}" = 1 ]; then
	for shape in "2950.0268341933147 3.106732490313113" "4.0 18.0" "120000.0 0.7"; do
		set -- $shape
		expect PASS "bound avgdl=$1 idf=$2" bound_harness.c harness_bound -DAVGDL=$1 -DIDF=$2
	done
	expect FAIL "bound TEETH (1.15.2 BMW order)" bound_harness.c harness_bound -DAVGDL=2950.0268341933147 -DIDF=3.106732490313113 -DTEETH_BMW_ORDER
	expect PASS bound_self      bound_harness.c harness_bound_self
	expect FAIL "bound_self TEETH (1.15.2 BMW order)" bound_harness.c harness_bound_self -DTEETH_BMW_ORDER
fi
expect FAIL "bound TEETH (exact v4 min len)" bound_harness.c harness_bound -DAVGDL=2950.0268341933147 -DIDF=3.106732490313113 -DTEETH_EXACT_MINDL
expect PASS mindl           bound_harness.c harness_mindl
# and the exhaustive native sweep: every posting/block within the bound at
# 2,000 corpus shapes (bound_exhaustive.c), and its mutant
if want bound_harness.c; then
	bx=$(mktemp -d)
	if cc -O2 -std=gnu99 -w bound_exhaustive.c -lm -o "$bx/be" && "$bx/be" 2000 | tail -1 | grep -q " 0 violations"; then
		echo "ok    bound_exhaustive (2,000 corpus shapes)  PASS as expected"
	else
		echo "BAD   bound_exhaustive found a violation"; FAIL=1
	fi
	if cc -O2 -std=gnu99 -w -DTEETH_BMW_ORDER bound_exhaustive.c -lm -o "$bx/bt" && ! "$bx/bt" 200 >/dev/null; then
		echo "ok    bound_exhaustive TEETH (1.15.2 BMW order)  FAIL as expected"
	else
		echo "BAD   bound_exhaustive TEETH not caught"; FAIL=1
	fi
fi

# 4. query-shape shortcuts never drop a match: every well-formed pure-boolean
#    RPN of up to 7 items, every document and segment term set.
QU="--unwind 9 --unwinding-assertions --object-bits 12"
expect PASS operands        query_harness.c harness_operands        $QU
expect PASS required_absent query_harness.c harness_required_absent $QU
expect PASS may_admit       query_harness.c harness_may_admit       $QU
expect PASS driver          query_harness.c harness_driver          $QU
expect PASS not_parity      query_harness.c harness_parity          $QU
expect FAIL "required_absent TEETH (NOT let through)" query_harness.c harness_required_absent -DTEETH_ABSENT_NOT $QU
expect FAIL "may_admit TEETH (no odd-NOT clear)"      query_harness.c harness_may_admit -DTEETH_MAYADMIT $QU
expect FAIL "driver TEETH (NOT operand drives)"       query_harness.c harness_driver -DTEETH_DRIVER $QU

# 1. the ranked traversals return exactly the brute-force top-k (VERBATIM
#    fts_search_bmw / fts_search_maxscore over a model cursor, integer scores,
#    any sound block and term bounds).  BMW serves 2-3 terms, MaxScore >= 4.
#    Every loop but the main document loop runs at most max(NT, ND) + 1
#    times; the main loop gets its own bound (one iteration per scored,
#    sought or skipped position).  --unwinding-assertions makes a bound that
#    is too small a FAIL, never a silent pass.
trav() {	# trav <PASS|FAIL> <label> <function> <NT> <ND> <main unwind> <defines...>
	local exp=$1 label=$2 fn=$3 nt=$4 nd=$5 mu=$6
	shift 6
	local main=$([ "$fn" = harness_bmw ] && echo fts_search_bmw.14 || echo fts_search_maxscore.12)
	expect "$exp" "$label" traversal_harness.c "$fn" -DNT=$nt -DND=$nd -DBLK=2 -DCMAX=2 "$@" \
		--unwind $((nd + 2)) --unwindset "$main:$mu" \
		--unwinding-assertions --object-bits 12
}
trav PASS "bmw 2 terms 3 docs k=1"     harness_bmw      2 3 10 -DK=1
trav PASS "bmw 2 terms 3 docs k=2"     harness_bmw      2 3 10 -DK=2
# MaxScore with 4 terms is the slowest proof (its mutant fails in ~20 min;
# the shipped code had no verdict after 2 h, 13 GB): CBMC_SLOW=1 to run it.
[ "${CBMC_SLOW:-0}" = 1 ] && trav PASS "maxscore 4 terms 3 docs k=1" harness_maxscore 4 3 8 -DK=1
trav FAIL "bmw TEETH (1.3.0..1.15.1 clamp)" harness_bmw      2 3 10 -DK=1 -DTEETH_PIVOT_CLAMP
trav FAIL "maxscore TEETH (1.10.0 suffix)"  harness_maxscore 4 3 8 -DK=1 -DTEETH_SUFFIX

# 6. sparsemap read cursor == cursor-free lookup (vendor/sm.c, #included).
SMU="--unwind 40 --unwindset layout_map.0:260 --unwinding-assertions --object-bits 12 -I../../vendor"
if want smcursor_harness.c; then
	# the layouts are serialized by the library natively, then embedded
	gd=$(mktemp -d)
	if cc -std=gnu99 -w -DGEN_LAYOUT -I../../vendor smcursor_harness.c -o "$gd/gen" &&
		"$gd/gen" > "$gd/layouts.h" && cmp -s "$gd/layouts.h" smcursor_layouts.h; then
		echo "ok    smcursor_layouts.h matches what vendor/sm.c writes"
	else
		echo "BAD   smcursor_layouts.h is stale (regenerate: see its first line)"; FAIL=1
	fi
fi
for L in 0 1 2 3; do
	expect PASS "sm_ascending layout=$L"  smcursor_harness.c harness_ascending  -DLAYOUT=$L $SMU
	expect PASS "sm_any_cursor layout=$L" smcursor_harness.c harness_any_cursor -DLAYOUT=$L $SMU
done
if want smcursor_harness.c; then
	mut=$(mktemp -d)/sm_mut.c
	python3 mutate_sm.py "$mut" || FAIL=1
	expect FAIL "sm_any_cursor TEETH (no neighbour check)" smcursor_harness.c harness_any_cursor -DLAYOUT=0 -DSM_SOURCE="\"$mut\"" $SMU
fi
# A finding in sparsemap, not a pg_fts gate: a stale prev_offset hint (not a
# chunk start) fools the gap resume.  Expected to FAIL until sparsemap
# validates the hint; then flip this to PASS.
expect FAIL "sm FINDING: stale prev_offset hint (sparsemap)" smcursor_harness.c harness_stale_hint -DLAYOUT=1 $SMU

# 7. shared doclen slot protocol (model of pg_fts_shdoclen.c's transitions):
#    every interleaving of two scans and a retiring merge.  Concurrent, but no
#    concurrent pointers, so CBMC 6.x runs it.
SHU="--unwind 6 --unwinding-assertions"
expect PASS shdoclen        shdoclen_harness.c main $SHU
expect FAIL "shdoclen TEETH (retire ignores readers)" shdoclen_harness.c main -DTEETH_RETIRE_REFD $SHU
expect FAIL "shdoclen TEETH (unref also unpins)"      shdoclen_harness.c main -DTEETH_UNREF_UNPINS $SHU

exit $FAIL
