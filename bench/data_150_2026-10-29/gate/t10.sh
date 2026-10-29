#!/bin/bash
# t10.sh: the new long_positions HTML probe on 1.14.3 (old17), 5a01219 (pre-review I9), and the fix (fix10), PG17;
# plus long_positions regress + t/004 on the fix (PG17 + PG18).
exec > /nvme/g150/t10.log 2>&1
Q='SELECT count(*) FILTER (WHERE to_ftsdoc($$english$$, repeat($$filler $$, n) || $$<a href="zzhref" class="zzclass"> word$$) @@@ $$zzhref | zzclass$$::ftsquery) AS tag_words_indexed, count(DISTINCT ftsdoc_length(to_ftsdoc($$english$$, repeat($$filler $$, n) || $$<a href="zzhref" class="zzclass"> word$$)) - n) AS doclen_shapes, count(*) AS offsets FROM generate_series(2330, 2350) n'
for L in old17 t9pfx17-pre t10pfx17; do
  B=/nvme/g150/$L/bin
  if [ $L = t10pfx17 ]; then [ -d /nvme/g150/$L ] || cp -a /nvme/pg17 /nvme/g150/$L; T=/nvme/g150/t10tree17; [ -d $T ] && mv $T /nvme/trash_t10_$RANDOM; mkdir -p $T; tar xzf /nvme/g150/fix10.tgz -C $T; (cd $T && make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1); fi
  D=/nvme/g150/t10d_$L; [ -d $D ] && mv $D /nvme/trash_t10_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=58817\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  $B/psql -X -q -h /tmp -p 58817 -U postgres -c "CREATE EXTENSION pg_fts"
  echo "$L ($($B/psql -X -At -h /tmp -p 58817 -U postgres -c "select extversion from pg_extension where extname='pg_fts'")): $($B/psql -X -At -h /tmp -p 58817 -U postgres -c "$Q")"
  $B/pg_ctl -D $D -w stop >/dev/null
done
for M in 17 18; do
  PFX=/nvme/g150/t10pfx$M; [ -d $PFX ] || cp -a /nvme/pg$M $PFX; B=$PFX/bin
  T=/nvme/g150/t10tree$M; [ -d $T ] || { mkdir -p $T; tar xzf /nvme/g150/fix10.tgz -C $T; }
  cd $T; make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
  D=/nvme/g150/t10r$M; [ -d $D ] && mv $D /nvme/trash_t10_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=589$M\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=589$M PGUSER=postgres REGRESS=long_positions ISOLATION= PROVE_TESTS=ci/noop.pl > /nvme/g150/t10_lp$M.log 2>&1; echo "PG$M long_positions rc=$? $(grep -E '^(ok|not ok)' /nvme/g150/t10_lp$M.log | tr '\n' ' ')"
  cp results/long_positions.out /nvme/g150/t10_lp$M.out 2>/dev/null
  $B/pg_ctl -D $D -w stop >/dev/null
  mv tmp_check /nvme/trash_t10_$RANDOM 2>/dev/null
  make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/004_encodings.pl > /nvme/g150/t10_004_$M.log 2>&1; echo "PG$M t/004 rc=$? $(grep -E '^t/|^Result' /nvme/g150/t10_004_$M.log | tr '\n' ' ')"
done
echo T10_DONE
