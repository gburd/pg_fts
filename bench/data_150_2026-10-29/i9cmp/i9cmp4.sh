#!/bin/bash
# i9cmp4.sh: the numbers cited in the CHANGELOG known issue (html-tags doc, config 'simple'), all three arms
exec > /nvme/i9cmp4.log 2>&1
for L in v1143 ours wide; do
  PORT=$(case $L in ours) echo 5601;; wide) echo 5602;; v1143) echo 5603;; esac); BB=/nvme/pfx-$L/bin
  Q="$BB/psql -X -At -h /tmp -p $PORT -U postgres -d c"
  echo "$L ($($Q -c "select extversion from pg_extension where extname='pg_fts'")): doclen(english)=$($Q -c "SET client_min_messages=warning" -c "SELECT ftsdoc_length(to_ftsdoc('english', t)) FROM docs2 WHERE id = 1" | tail -1) href=$($Q -c "SELECT to_ftsdoc('english', t) @@@ 'href'::ftsquery FROM docs2 WHERE id = 1") class=$($Q -c "SELECT to_ftsdoc('english', t) @@@ 'class'::ftsquery FROM docs2 WHERE id = 1") phrase_t_wN_of_4999=$($Q -c "SELECT count(*) FROM docs2, generate_series(1,4999) g WHERE id = 1 AND to_ftsdoc('simple', t) @@@ ('\"t w' || (g+1) || '\"')::ftsquery")"
done
echo I9CMP4_DONE
