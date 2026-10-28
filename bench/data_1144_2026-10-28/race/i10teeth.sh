#!/bin/bash
# I10 teeth: run the CI sanitizers smoke step (extracted from ci.yml) against (a) the tree and (b) a mutant that writes
# one double past fts_bm25's dfs copy and then pfrees it (a palloc overflow ASan cannot see).  (a) must pass,
# (b) must fail on the new "write past chunk end" grep.  ASan PG17 at /nvme/pg17asan.
set -uo pipefail
exec > /nvme/rm/i10teeth.log 2>&1
PFX=/nvme/pg17asan; export ASAN_OPTIONS=detect_leaks=0
for arm in tree mutant; do
  T=/nvme/rm/i10-$arm; [ -d $T ] && mv $T /nvme/trash_i10_$RANDOM; mkdir -p $T; tar xzf /nvme/rm/i20.tgz -C $T; cd $T
  if [ $arm = mutant ]; then
    python3 - <<'PY'
s=open('pg_fts_rank.c').read()
old="""		dfs = (double *) palloc(ndfs * sizeof(double));
		for (i = 0; i < ndfs; i++)
			dfs[i] = nulls[i] ? 1.0 : DatumGetFloat8(elems[i]);
	}

	if (N < 1.0)
		N = 1.0;

	score = fts_bm25_score(doc, q, N, avgdl, dfs, ndfs,
						   BM25_DEFAULT_K1, BM25_DEFAULT_B, BM25_LUCENE);
"""
new="""		dfs = (double *) palloc(ndfs * sizeof(double));
		for (i = 0; i < ndfs; i++)
			dfs[i] = nulls[i] ? 1.0 : DatumGetFloat8(elems[i]);
		((volatile double *) dfs)[ndfs] = 42.0;	/* I10 MUTANT: one past the end */
	}

	if (N < 1.0)
		N = 1.0;

	score = fts_bm25_score(doc, q, N, avgdl, dfs, ndfs,
						   BM25_DEFAULT_K1, BM25_DEFAULT_B, BM25_LUCENE);
	if (dfs)
		pfree(dfs);				/* I10 MUTANT: cassert checks the sentinel here */
"""
assert s.count(old)==1; open('pg_fts_rank.c','w').write(s.replace(old,new))
PY
    echo "mutant lines: $(grep -c 'I10 MUTANT' pg_fts_rank.c)"
  fi
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
  make -s CC=clang PG_CONFIG="$PFX/bin/pg_config" with_llvm=no COPT="-fsanitize=address -fno-omit-frame-pointer -g -O1 -DUSE_ASSERT_CHECKING" SHLIB_LINK="-fsanitize=address" >/nvme/rm/i10-$arm-build.log 2>&1 || { echo "$arm BUILD_FAIL"; continue; }
  make -s install PG_CONFIG="$PFX/bin/pg_config" >/dev/null 2>&1
  python3 - <<'PY' > /nvme/rm/i10-step.sh
y=open('.github/workflows/ci.yml').read()
i=y.index('- name: Smoke the in-process paths under an ASan-built PostgreSQL')
j=y.index('        run: |', i); k=y.index('      - name:', j)
print('\n'.join(l[10:] for l in y[j:k].split('\n')[1:]))
PY
  [ -s /nvme/rm/i10-step.sh ] || { echo "$arm STEP_EXTRACT_FAIL"; continue; }
  echo "$arm: step has chunk-end grep: $(grep -c 'detected write past chunk end' /nvme/rm/i10-step.sh); so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
  PFX=$PFX bash -eo pipefail /nvme/rm/i10-step.sh > /nvme/rm/i10-$arm-step.log 2>&1; rc=$?
  $PFX/bin/pg_ctl -D $T/asandata -m immediate -w stop >/dev/null 2>&1
  echo "$arm: step rc=$rc; smoke: $(grep -c 'asan_smoke: all checks passed' /nvme/rm/i10-$arm-step.log); chunk-end WARNINGs in server log: $(grep -c 'detected write past chunk end' $T/asandata/log); ASan reports: $(grep -c 'ERROR: AddressSanitizer' $T/asandata/log); last step line: $(tail -1 /nvme/rm/i10-$arm-step.log | cut -c1-120)"
done
echo I10TEETH_DONE
