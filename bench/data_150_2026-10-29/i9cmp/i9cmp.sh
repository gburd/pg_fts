#!/bin/bash
# i9cmp.sh: 1.15.0's chunked configured analyzer vs the downstream "wide parser" (jimdawdy-hub/pg_fts
# upgrade/freecase-130-20261015 a0b5355: PostgreSQL's ts_parse.c vendored with a 30-bit position counter, no chunking).
# The wide parser has no chunk boundaries, so it is the reference for documents over 16,383 tokens.  Same PG 17.10,
# separate prefixes; to_ftsdoc(cfg, text)::text compared byte for byte over generated long documents.
set -uo pipefail
exec > /nvme/i9cmp.log 2>&1
for L in ours wide; do
  P=/nvme/pfx-$L; [ -d $P ] || cp -a /nvme/pg17 $P; B=$P/bin
  S=/nvme/src-$L; [ -d $S ] && mv $S /nvme/trash_c_$RANDOM; mkdir -p $S
  if [ $L = ours ]; then cd $S && unzip -q /nvme/pg_fts-1.15.0.zip && cd pg_fts-1.15.0; else tar xzf /nvme/jd130.tgz -C $S && cd $S; fi
  make -s -j16 PG_CONFIG=$B/pg_config 2>&1 | grep -E "error:" | head -3; make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1
  D=/nvme/d-$L; [ -d $D ] && mv $D /nvme/trash_c_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  PORT=$([ $L = ours ] && echo 5601 || echo 5602)
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf; $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  $B/psql -X -q -h /tmp -p $PORT -U postgres -c "CREATE DATABASE c TEMPLATE template0 ENCODING 'UTF8' LC_CTYPE 'C.UTF-8' LC_COLLATE 'C'" -c "\\c c" -c "CREATE EXTENSION pg_fts"
  echo "$L: $($B/psql -X -At -h /tmp -p $PORT -U postgres -d c -c "select extversion from pg_extension where extname='pg_fts'") so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
done
# the documents: generated once, the same bytes to both servers
cat > /nvme/i9docs.sql <<'SQL'
CREATE TABLE docs AS
SELECT 1 AS id, 'plain' AS kind, repeat('alpha beta gamma delta ', 6000) AS t                      -- 24,000 tokens
UNION ALL SELECT 2, 'html-tags-every-200b', string_agg('<a href="x' || g || '" class="c y z"> word' || g || ' and more text here ', '') FROM generate_series(1, 2000) g
UNION ALL SELECT 3, 'html-comments', string_agg('<!-- a comment with spaces ' || g || ' --> body' || g || ' text ', '') FROM generate_series(1, 3000) g
UNION ALL SELECT 4, 'urls-emails', string_agg('see https://ex.com/p?q=' || g || '&r=s and mail u' || g || '@ex.org now ', '') FROM generate_series(1, 2500) g
UNION ALL SELECT 5, 'hyphenated', string_agg('state-of-the-art ' || g || ' co-op re-entry well-known ', '') FROM generate_series(1, 4000) g
UNION ALL SELECT 6, 'cjk-no-space', repeat(convert_from('\xe6bca2e5ad97e69687e7aba0'::bytea, 'UTF8'), 3000) || repeat(' w', 17000)
UNION ALL SELECT 7, 'cjk-spaced', repeat(convert_from('\xe6bca2e5ad97'::bytea, 'UTF8') || ' ', 20000)
UNION ALL SELECT 8, 'script-style', string_agg('<script>var a' || g || ' = 1;</script> visible' || g || ' <style>.c{x:y}</style> ', '') FROM generate_series(1, 2500) g
UNION ALL SELECT 9, 'numbers', string_agg(g::text || '.5 ' || (g*3)::text || ' -' || g::text || ' ', '') FROM generate_series(1, 8000) g
UNION ALL SELECT 10, 'long-words', string_agg(repeat('x', 40) || g || ' ', '') FROM generate_series(1, 18000) g;
SQL
for L in ours wide; do PORT=$([ $L = ours ] && echo 5601 || echo 5602); /nvme/pfx-$L/bin/psql -X -q -h /tmp -p $PORT -U postgres -d c -f /nvme/i9docs.sql; done
for cfg in simple english; do
  echo "== config $cfg"
  for id in 1 2 3 4 5 6 7 8 9 10; do
    q="SELECT kind, length(t), ftsdoc_length(to_ftsdoc('$cfg', t)), md5(to_ftsdoc('$cfg', t)::text) FROM docs WHERE id = $id"
    a=$(/nvme/pfx-ours/bin/psql -X -At -h /tmp -p 5601 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    b=$(/nvme/pfx-wide/bin/psql -X -At -h /tmp -p 5602 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    echo "  $id $([ "$a" = "$b" ] && echo SAME || echo DIFF) ours=[$a] wide=[$b]"
  done
done
echo I9CMP_DONE
