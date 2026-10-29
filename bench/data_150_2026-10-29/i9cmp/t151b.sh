#!/bin/bash
# t151b.sh: long_positions regress on the revised fix (PG17) -> results file; the lpl block on 1.15.0 and wide; t/004
exec > /nvme/t151b.log 2>&1
B=/nvme/pfx-fix/bin; S=/nvme/src-fix; [ -d $S ] && mv $S /nvme/trash_c_$RANDOM; mkdir -p $S; tar xzf /nvme/r151b.tgz -C $S; cd $S
make -s -j16 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
D=/nvme/d-fixr; $B/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_c_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1; printf "port=5605\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; $B/pg_ctl -D $D -l $D/log -w start >/dev/null
s=$(date +%s); make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=5605 PGUSER=postgres REGRESS=long_positions ISOLATION= PROVE_TESTS=ci/noop.pl > /nvme/t151b_lp.log 2>&1; echo "long_positions rc=$? in $(( $(date +%s)-s )) s: $(grep -E '^(ok|not ok)' /nvme/t151b_lp.log)"; cp results/long_positions.out /nvme/t151b_lp.out
$B/pg_ctl -D $D -w stop >/dev/null
sed -n '/^CREATE TABLE lpl/,/^DROP TABLE lpl;/p' sql/long_positions.sql > /nvme/lpl.sql
for L in ours wide; do PORT=$([ $L = ours ] && echo 5601 || echo 5602); echo "== lpl on $L: $(/nvme/pfx-$L/bin/psql -X -At -h /tmp -p $PORT -U postgres -d c -c 'SET client_min_messages=warning' -f /nvme/lpl.sql 2>&1 | grep -E '^[0-9]' | tr '\n' ' ')"; done
mv tmp_check /nvme/trash_c_$RANDOM 2>/dev/null; make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/004_encodings.pl > /nvme/t151b_004.log 2>&1; echo "t/004 rc=$? $(grep -E '^t/|^Result' /nvme/t151b_004.log | tr '\n' ' ')"
echo T151B_DONE
