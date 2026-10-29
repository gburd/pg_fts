#!/bin/bash
# t151.sh: the new long_positions block on 1.15.0 (ours) and on the fix, PG17; then long_positions + t/004 regress on the fix
exec > /nvme/t151.log 2>&1
cat > /nvme/lpm.sql <<'SQL'
SET client_min_messages = warning;
DROP TABLE IF EXISTS lpm;
CREATE TABLE lpm AS
SELECT 1 AS id, string_agg('<a href="x' || g || '" class="c y z"> w' || g || ' v u t ', '') AS t FROM generate_series(1, 5000) g
UNION ALL SELECT 2, string_agg('<!-- a comment with spaces ' || g || ' --> b' || g || ' c d e ', '') FROM generate_series(1, 5000) g
UNION ALL SELECT 3, string_agg('<script>var a' || g || ' = 1;</script> v' || g || ' w x y <style>.c{x:y}</style> ', '') FROM generate_series(1, 5000) g;
ALTER TABLE lpm ADD COLUMN d ftsdoc;
UPDATE lpm SET d = to_ftsdoc('simple', t);
SELECT id, ftsdoc_length(d), d @@@ 'href | class'::ftsquery, d @@@ 'comment | spaces'::ftsquery, d @@@ 'var'::ftsquery FROM lpm ORDER BY id;
SELECT count(*) FROM lpm, generate_series(1, 4999) g WHERE id = 1 AND d @@@ ('"t w' || (g + 1) || '"')::ftsquery;
SQL
for L in ours wide; do PORT=$([ $L = ours ] && echo 5601 || echo 5602); echo "== $L"; /nvme/pfx-$L/bin/psql -X -At -h /tmp -p $PORT -U postgres -d c -f /nvme/lpm.sql; done
P=/nvme/pfx-fix; B=$P/bin; S=/nvme/src-fix; [ -d $S ] && mv $S /nvme/trash_c_$RANDOM; mkdir -p $S; tar xzf /nvme/r151.tgz -C $S; cd $S
make -s -j16 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
$B/pg_ctl -D /nvme/d-fix -l /nvme/d-fix/log -w restart >/dev/null
echo "== fix"; $B/psql -X -At -h /tmp -p 5604 -U postgres -d c -f /nvme/lpm.sql
D=/nvme/d-fixr; [ -d $D ] && mv $D /nvme/trash_c_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1; printf "port=5605\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; $B/pg_ctl -D $D -l $D/log -w start >/dev/null
make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=5605 PGUSER=postgres REGRESS=long_positions ISOLATION= PROVE_TESTS=ci/noop.pl > /nvme/t151_lp.log 2>&1; echo "long_positions rc=$?"; cp results/long_positions.out /nvme/t151_lp.out
$B/pg_ctl -D $D -w stop >/dev/null
mv tmp_check /nvme/trash_c_$RANDOM 2>/dev/null; make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/004_encodings.pl > /nvme/t151_004.log 2>&1; echo "t/004 rc=$? $(grep -E '^t/|^Result' /nvme/t151_004.log | tr '\n' ' ')"
echo T151_DONE
