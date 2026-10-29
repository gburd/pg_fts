#!/bin/bash
# t151c.sh: the re-review revision: 32-probe md5 vs wide; long_positions regress (results); lpm/lpl on 1.15.0 for the
# FAIL side; t/004.
exec > /nvme/t151c.log 2>&1
B=/nvme/pfx-fix/bin; S=/nvme/src-fix; [ -d $S ] && mv $S /nvme/trash_c_$RANDOM; mkdir -p $S; tar xzf /nvme/r151c.tgz -C $S; cd $S
make -s -j16 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
$B/pg_ctl -D /nvme/d-fix -l /nvme/d-fix/log -w restart >/dev/null
echo "fix tree $(cat GITREV) so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
same=0; diff=0
for cfg in simple english; do for tb in docs docs2 docs3; do
  for id in $($B/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "select id from $tb order by id"); do
    q="SELECT kind, ftsdoc_length(to_ftsdoc('$cfg', t)), md5(to_ftsdoc('$cfg', t)::text) FROM $tb WHERE id = $id"
    a=$($B/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    b=$(/nvme/pfx-wide/bin/psql -X -At -h /tmp -p 5602 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    if [ "$a" = "$b" ]; then same=$((same+1)); else diff=$((diff+1)); echo "  DIFF $cfg $tb $id fix=[$a] wide=[$b]"; fi
  done
done; done
echo "fix vs wide: SAME $same DIFF $diff (of 32)"
echo "fallback DEBUG1 over all 32: $(for cfg in simple english; do for tb in docs docs2 docs3; do $B/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "SET client_min_messages=debug1" -c "SELECT count(*) FROM $tb WHERE ftsdoc_length(to_ftsdoc('$cfg', t)) >= 0" 2>&1 | grep -c 'no verified chunk cut'; done; done | paste -sd+ | bc)"
D=/nvme/d-fixr; $B/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_c_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1; printf "port=5605\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; $B/pg_ctl -D $D -l $D/log -w start >/dev/null
s=$(date +%s); make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=5605 PGUSER=postgres REGRESS=long_positions ISOLATION= PROVE_TESTS=ci/noop.pl > /nvme/t151c_lp.log 2>&1; echo "long_positions rc=$? in $(( $(date +%s)-s )) s"; cp results/long_positions.out /nvme/t151c_lp.out
$B/pg_ctl -D $D -w stop >/dev/null
sed -n '/^-- markup over 16,383 tokens/,/^DROP TABLE lpl;/p' sql/long_positions.sql | grep -v "^--" > /nvme/lpm3.sql
for L in ours wide; do PORT=$([ $L = ours ] && echo 5601 || echo 5602); echo "== new blocks on $L: $(/nvme/pfx-$L/bin/psql -X -At -h /tmp -p $PORT -U postgres -d c -c 'SET client_min_messages=warning' -c 'DROP TABLE IF EXISTS lpm, lpl' -f /nvme/lpm3.sql 2>&1 | grep -E '^[0-9]' | tr '\n' ' ')"; done
mv tmp_check /nvme/trash_c_$RANDOM 2>/dev/null; make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/004_encodings.pl > /nvme/t151c_004.log 2>&1; echo "t/004 rc=$? $(grep -E '^t/|^Result' /nvme/t151c_004.log | tr '\n' ' ')"
echo T151C_DONE
