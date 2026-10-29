#!/bin/bash
# t9.sh: reviewer findings 1+2 on the fixed tree (fix9.tgz) and on 5a01219 (the tree gated before the review), PG17+18:
# t/004 (new UTF-8 chunk case) must FAIL on 5a01219 and PASS on the fix; i9mb probes; long_positions regression.
exec > /nvme/g150/t9.log 2>&1
for L in pre fix; do for M in 17 18; do
  PFX=/nvme/g150/t9pfx$M-$L; [ -d $PFX ] || cp -a /nvme/pg$M $PFX; B=$PFX/bin
  T=/nvme/g150/t9tree$M-$L; [ -d $T ] && mv $T /nvme/trash_t9_$RANDOM; mkdir -p $T; tar xzf /nvme/g150/fix9.tgz -C $T
  [ $L = pre ] && cp /nvme/g150/old9/pg_fts_tsanalyze.c $T/pg_fts_tsanalyze.c
  cd $T; make -s -j32 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
  echo "== $L PG$M so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) whole-parse-first=$(grep -c 'past the cap: parse again' pg_fts_tsanalyze.c) mbcliplen=$(grep -c pg_mbcliplen pg_fts_tsanalyze.c)"
  make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS='t/004_encodings.pl' > /nvme/g150/t9_004_${L}_$M.log 2>&1; echo "t/004 rc=$?: $(grep -E '^t/|^Result|not ok' /nvme/g150/t9_004_${L}_$M.log | tr '\n' ' ')"
  grep -E "not ok|invalid byte" tmp_check/log/regress_log_004_encodings 2>/dev/null | head -3
done; done
echo T9_DONE
