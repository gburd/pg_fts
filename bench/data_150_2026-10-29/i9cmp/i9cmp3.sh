#!/bin/bash
# i9cmp3.sh: does the 1.15.0 chunk boundary change MATCHES (not just bytes)?  html-tags doc (5,000 tags, 20,000 words):
# @@@ for a tag-attribute word, for a phrase across a boundary, and the 1.14.3 answer (PGXN zip) as a third arm.
exec > /nvme/i9cmp3.log 2>&1
P=/nvme/pfx-v1143; [ -d $P ] || cp -a /nvme/pg17 $P; B=$P/bin
cd /nvme; [ -f pg_fts-1.14.3.zip ] || curl -sfLO https://api.pgxn.org/dist/pg_fts/1.14.3/pg_fts-1.14.3.zip
S=/nvme/src-v1143; [ -d $S ] || { mkdir -p $S; cd $S && unzip -q /nvme/pg_fts-1.14.3.zip; }; cd $S/pg_fts-1.14.3 && make -s -j16 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
D=/nvme/d-v1143; [ -d $D ] || { $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1; printf "port=5603\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; }
$B/pg_ctl -D $D -l $D/log -w start >/dev/null 2>&1
$B/psql -X -q -h /tmp -p 5603 -U postgres -c "CREATE DATABASE c TEMPLATE template0 ENCODING 'UTF8' LC_CTYPE 'C.UTF-8' LC_COLLATE 'C'" 2>/dev/null; $B/psql -X -q -h /tmp -p 5603 -U postgres -d c -c "CREATE EXTENSION IF NOT EXISTS pg_fts" -f /nvme/i9docs2.sql 2>/dev/null
for L in v1143 ours wide; do
  PORT=$(case $L in ours) echo 5601;; wide) echo 5602;; v1143) echo 5603;; esac); BB=/nvme/pfx-$L/bin
  $BB/pg_ctl -D /nvme/d-$L -l /nvme/d-$L/log -w start >/dev/null 2>&1
  r=$($BB/psql -X -At -h /tmp -p $PORT -U postgres -d c -c "SET client_min_messages=warning" -c "
    SELECT string_agg(q || '=' || (to_ftsdoc('english', t) @@@ q::ftsquery)::text, ' ' ORDER BY q)
      FROM docs2, unnest(ARRAY['href', 'class', '\"w4900 v u t\"', '\"w2 v u t\"', '\"t w4901\"', '\"w4100 v u t\"']) q WHERE id = 1" | tail -1)
  echo "$L ($($BB/psql -X -At -h /tmp -p $PORT -U postgres -d c -c "select extversion from pg_extension where extname='pg_fts'")): $r"
done
echo I9CMP3_DONE
