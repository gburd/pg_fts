#!/bin/bash
# t013ab.sh: t/013 must FAIL with the 1.14.2 .so and PASS with the fix (tree 7f233ca), PG17 + PG18, 3 runs each.
# Uses the gate prefixes $G/pfx<M> (fresh copies of /nvme/pg<M>); the 1.14.2 arm swaps in v1142's .so.
G=/nvme/iss/gate; exec > $G/t013ab.log 2>&1
for M in 17 18; do
  PFX=$G/pfx$M; B=$PFX/bin; LIB=$($B/pg_config --pkglibdir)
  T=$G/t013tree$M; [ -d $T ] && mv $T /nvme/trash_t13_$RANDOM; mkdir -p $T; tar xzf $G/t013.tgz -C $T; cd $T
  make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
  cp $LIB/pg_fts.so $G/so_fix_$M.so
  echo "== PG$M tree $(cat GITREV) fix so $(md5sum $G/so_fix_$M.so | cut -c1-8) v1142 so $(md5sum /nvme/iss/pg$M-v1142/lib/postgresql/pg_fts.so | cut -c1-8); keep-last in source: $(grep -c 'gen_retries++ >= 10' pg_fts_am_scan.c)"
  for arm in v1142 fix v1142 fix v1142 fix; do
    if [ $arm = v1142 ]; then cp /nvme/iss/pg$M-v1142/lib/postgresql/pg_fts.so $LIB/pg_fts.so; else cp $G/so_fix_$M.so $LIB/pg_fts.so; fi
    mv tmp_check /nvme/trash_t13_$RANDOM 2>/dev/null
    r=$(make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/013_ranked_flush_race.pl 2>&1)
    echo "PG$M $arm so=$(md5sum $LIB/pg_fts.so | cut -c1-8): $(echo "$r" | grep -E '^Result|^t/013' | tr '\n' ' ') $(echo "$r" | grep -E 'Failed test|got:|expected:|inserters wrote' | head -4 | tr -s ' ' | tr '\n' ' ')"
  done
  cp $G/so_fix_$M.so $LIB/pg_fts.so
done
echo T013AB_DONE
