#!/bin/bash
# reviewer finding 1 (I9 hard cut splits a UTF-8 character) and finding 2 (HTML under 16,383 tokens tokenized differently):
# 1.14.3 (old arm, /nvme/g150/old17) vs the release tree (/nvme/g150/pfx17), PG17, a UTF8 database with C.UTF-8 ctype.
for L in old17 t9pfx17-fix; do
  B=/nvme/g150/$L/bin; D=/nvme/g150/mb_$L; P=$([ $L = old17 ] && echo 58517 || echo 58617)
  $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_mb_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  $B/psql -X -q -h /tmp -p $P -U postgres -c "CREATE DATABASE u TEMPLATE template0 ENCODING 'UTF8' LC_CTYPE 'C.UTF-8' LC_COLLATE 'C.UTF-8'"
  Q="$B/psql -X -At -h /tmp -p $P -U postgres -d u"
  $Q -c "CREATE EXTENSION pg_fts" >/dev/null
  echo "== $L $($Q -c "select extversion from pg_extension where extname='pg_fts'") ctype $($Q -c 'select datctype from pg_database where datname = current_database()')"
  echo "  f1 multibyte, no whitespace, 20,000 bytes: $($Q -c "SET client_min_messages = warning; SELECT ftsdoc_length(to_ftsdoc('simple', repeat('é漢', 4000)))" 2>&1 | head -1)"
  echo "  f1 same, under 16,383 bytes: $($Q -c "SET client_min_messages = warning; SELECT ftsdoc_length(to_ftsdoc('simple', repeat('é漢', 3000)))" 2>&1 | head -1)"
  # f2: an HTML tag with spaces straddling the first 16,383-byte boundary, document far below 16,383 tokens
  $Q -c "CREATE TABLE h AS SELECT n, repeat('x', n) || ' <a href=\"zzhref\" class=\"zzclass\"> word ' || repeat('y ', 10) AS t FROM generate_series(16340, 16400) n" >/dev/null
  echo "  f2 html: md5 of to_ftsdoc over 61 offsets: $($Q -c "SELECT md5(string_agg(to_ftsdoc('english', t)::text, '|' ORDER BY n)) FROM h")  tag words indexed in how many: $($Q -c "SELECT count(*) FROM h WHERE to_ftsdoc('english', t) @@@ 'zzhref | zzclass'::ftsquery")"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done
