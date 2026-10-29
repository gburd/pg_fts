#!/bin/bash
# i9cmp6.sh: the review-revised I9a fix (r151b) vs the exact wide parser: 28 probes + 2 long-markup probes (a 40 kB
# <script> body; a 30 kB data: URI tag) that defeat the token-boundary cut; the long_positions block on 1.15.0 / fix;
# analyzer timing (median of 5).
exec > /nvme/i9cmp6.log 2>&1
B=/nvme/pfx-fix/bin; S=/nvme/src-fix; [ -d $S ] && mv $S /nvme/trash_c_$RANDOM; mkdir -p $S; tar xzf /nvme/r151b.tgz -C $S; cd $S
make -s -j16 PG_CONFIG=$B/pg_config 2>&1 | grep -E "warning:|error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
$B/pg_ctl -D /nvme/d-fix -l /nvme/d-fix/log -w restart >/dev/null
echo "fix tree $(cat $S/GITREV) so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
cat > /nvme/i9docs3.sql <<'SQL'
DROP TABLE IF EXISTS docs3;
CREATE TABLE docs3 AS
SELECT 1 AS id, 'long-script' AS kind, repeat('w ', 9000) || '<script>' || repeat('var zz = 1; ', 3500) || '</script>' || repeat(' w', 9000) AS t
UNION ALL SELECT 2, 'long-data-uri', repeat('w ', 9000) || '<img src="data:image/png;base64,' || repeat('QUJD', 7500) || '"> tail' || repeat(' w', 9000);
SQL
for L in ours fix wide; do PORT=$(case $L in ours) echo 5601;; wide) echo 5602;; fix) echo 5604;; esac); /nvme/pfx-$L/bin/pg_ctl -D /nvme/d-$L -l /nvme/d-$L/log -w start >/dev/null 2>&1; /nvme/pfx-$L/bin/psql -X -q -h /tmp -p $PORT -U postgres -d c -f /nvme/i9docs3.sql 2>&1 | grep -v NOTICE; done
same=0; diff=0
for cfg in simple english; do for tb in docs docs2 docs3; do
  for id in $(/nvme/pfx-fix/bin/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "select id from $tb order by id"); do
    q="SELECT kind, ftsdoc_length(to_ftsdoc('$cfg', t)), md5(to_ftsdoc('$cfg', t)::text) FROM $tb WHERE id = $id"
    a=$(/nvme/pfx-fix/bin/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    b=$(/nvme/pfx-wide/bin/psql -X -At -h /tmp -p 5602 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    o=$(/nvme/pfx-ours/bin/psql -X -At -h /tmp -p 5601 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    if [ "$a" = "$b" ]; then same=$((same+1)); else diff=$((diff+1)); echo "  DIFF $cfg $tb $id fix=[$a] wide=[$b] 1.15.0=[$o]"; fi
  done
done; done
echo "fix vs wide: SAME $same DIFF $diff (of 32)"
echo "fallback DEBUG1 on the long-markup probes: $(/nvme/pfx-fix/bin/psql -X -At -h /tmp -p 5604 -U postgres -d c -c "SET client_min_messages=debug1" -c "SELECT count(*) FROM docs3 WHERE ftsdoc_length(to_ftsdoc('simple', t)) > 0" 2>&1 | grep -c 'no verified chunk cut')"
sed -n '/^-- markup over 16,383 tokens/,/^DROP TABLE lpm;/p' $S/sql/long_positions.sql > /nvme/lpm2.sql
for L in ours fix; do PORT=$([ $L = ours ] && echo 5601 || echo 5604); echo "== long_positions block on $L"; /nvme/pfx-$L/bin/psql -X -At -h /tmp -p $PORT -U postgres -d c -c "SET client_min_messages=warning" -f /nvme/lpm2.sql 2>&1 | grep -E "^[0-9]"; done
for L in ours fix; do PORT=$([ $L = ours ] && echo 5601 || echo 5604); BB=/nvme/pfx-$L/bin
  ms=$( { echo "SET client_min_messages=warning;"; echo "\\timing on"; for i in $(seq 7); do echo "SELECT sum(ftsdoc_length(to_ftsdoc('english', t))) FROM docs2;"; done; } | $BB/psql -X -h /tmp -p $PORT -U postgres -d c 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -5 | sort -n | sed -n 3p)
  echo "analyze the 4 long-markup docs of docs2 (english), median of 5: $L $ms ms"; done
echo I9CMP6_DONE
