#!/bin/bash
# i9cmp5.sh: the I9a fix (r151 working tree) vs the exact wide parser: all 14 long documents x 2 configs; the cited numbers.
exec > /nvme/i9cmp5.log 2>&1
P=/nvme/pfx-fix; [ -d $P ] || cp -a /nvme/pg17 $P; B=$P/bin
S=/nvme/src-fix; [ -d $S ] && mv $S /nvme/trash_c_$RANDOM; mkdir -p $S; tar xzf /nvme/r151.tgz -C $S; cd $S
make -s -j16 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
D=/nvme/d-fix; [ -d $D ] || { $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1; printf "port=5604\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; }
$B/pg_ctl -D $D -l $D/log -w restart >/dev/null 2>&1 || $B/pg_ctl -D $D -l $D/log -w start >/dev/null
$B/psql -X -q -h /tmp -p 5604 -U postgres -c "CREATE DATABASE c TEMPLATE template0 ENCODING 'UTF8' LC_CTYPE 'C.UTF-8' LC_COLLATE 'C'" 2>/dev/null
$B/psql -X -q -h /tmp -p 5604 -U postgres -d c -c "DROP EXTENSION IF EXISTS pg_fts CASCADE" -c "CREATE EXTENSION pg_fts" -c "DROP TABLE IF EXISTS docs" -f /nvme/i9docs.sql -f /nvme/i9docs2.sql 2>&1 | grep -v NOTICE
echo "fix tree $(cat $S/GITREV) so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
for L in wide; do /nvme/pfx-$L/bin/pg_ctl -D /nvme/d-$L -l /nvme/d-$L/log -w start >/dev/null 2>&1; done
same=0; diff=0
for cfg in simple english; do for tb in docs docs2; do
  for id in $(/nvme/pfx-fix/bin/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "select id from $tb order by id"); do
    q="SELECT kind, ftsdoc_length(to_ftsdoc('$cfg', t)), md5(to_ftsdoc('$cfg', t)::text) FROM $tb WHERE id = $id"
    a=$(/nvme/pfx-fix/bin/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    b=$(/nvme/pfx-wide/bin/psql -X -At -h /tmp -p 5602 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    if [ "$a" = "$b" ]; then same=$((same+1)); else diff=$((diff+1)); echo "  DIFF $cfg $tb $id fix=[$a] wide=[$b]"; fi
  done
done; done
echo "fix vs wide: SAME $same DIFF $diff"
Q="/nvme/pfx-fix/bin/psql -X -At -h /tmp -p 5604 -U postgres -d c"
echo "fix: doclen(english)=$($Q -c "SET client_min_messages=warning" -c "SELECT ftsdoc_length(to_ftsdoc('english', t)) FROM docs2 WHERE id = 1" | tail -1) href=$($Q -c "SELECT to_ftsdoc('english', t) @@@ 'href'::ftsquery FROM docs2 WHERE id = 1") class=$($Q -c "SELECT to_ftsdoc('english', t) @@@ 'class'::ftsquery FROM docs2 WHERE id = 1") phrase_t_wN_of_4999=$($Q -c "SELECT count(*) FROM docs2, generate_series(1,4999) g WHERE id = 1 AND to_ftsdoc('simple', t) @@@ ('\"t w' || (g+1) || '\"')::ftsquery")"
# timing: the long-document analyzer cost, 1.15.0 vs fix (median of 5)
for L in ours fix; do PORT=$([ $L = ours ] && echo 5601 || echo 5604); BB=/nvme/pfx-$L/bin
  ms=$( { echo "SET client_min_messages=warning;"; echo "\\timing on"; for i in $(seq 7); do echo "SELECT sum(ftsdoc_length(to_ftsdoc('english', t))) FROM docs2;"; done; } | $BB/psql -X -h /tmp -p $PORT -U postgres -d c 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -5 | sort -n | sed -n 3p)
  echo "analyze 4 long HTML docs (english), median of 5: $L $ms ms"; done
echo I9CMP5_DONE
