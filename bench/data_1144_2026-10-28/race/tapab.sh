#!/bin/bash
# t/014 + t/015 x3 on the 1.14.3+hooks control (must FAIL) and on the fix+hooks (must PASS), PG17 + PG18
exec > /nvme/rm/tapab.log 2>&1
export PG_FTS_TEST_HOOKS_BUILD=1; TAPS=${TAPS:-"t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl"}
for L in v1143h i20h; do
  TGZ=/nvme/rm/i20.tgz; [ $L = v1143h ] && TGZ=/nvme/rm/v1143hook.tgz
  for M in 17 18; do
    B=/nvme/rm/pfx$M-$L/bin; T=/nvme/rm/src$M-$L
    for f in t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl; do tar xzf $TGZ -C $T ./$f 2>/dev/null || tar xzf $TGZ -C $T $f; done
    cd $T
    for r in 1 2 3; do
      mv tmp_check /nvme/trash_ta_$RANDOM 2>/dev/null
      out=$(make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS="$TAPS" 2>&1)
      echo "PG$M $L run $r: $(echo "$out" | grep -E '^t/0|^Result' | tr -s ' ' | tr '\n' ' ') $(echo "$out" | grep -E 'rebuild errors' | sed 's/^# //')"
      echo "$out" | grep -E "Failed test|got:|expected:" | head -12 | sed 's/^/    /'
    done
  done
done
echo TAPAB_DONE
