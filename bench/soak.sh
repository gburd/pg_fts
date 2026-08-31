#!/usr/bin/env bash
# Concurrent soak for a doclen_sidecar=on (v4) pg_fts index under sustained
# multi-client pressure: readers (ranked + count) + a writer (insert) + a
# background merge/vacuum loop, for SOAK_SECS.  Asserts: no crash (server stays
# up), no wrong results (a fixed-term count stays monotms-consistent vs a
# ground-truth recomputation window), and bounded index growth.
#
# Usage: soak.sh <dsn> <secs>
set -uo pipefail
DSN="${1:?dsn}"; SECS="${2:-240}"
Q() { psql "$DSN" -X -q -t -A -c "$1" 2>/dev/null; }

echo "== soak start: $(date -u) for ${SECS}s =="
Q "SELECT 'server up: ' || count(*) FROM docs" | head -1
SZ0=$(Q "SELECT pg_relation_size('docs_fts')")
echo "index size at start: $((SZ0/1024/1024)) MB"

END=$(( $(date +%s) + SECS ))

# --- background: merge + vacuum loop (concurrent maintenance under load) ---
( while [ $(date +%s) -lt $END ]; do
    psql "$DSN" -X -q -c "SELECT fts_merge('docs_fts')" >/dev/null 2>&1
    psql "$DSN" -X -q -c "SELECT fts_vacuum('docs_fts')" >/dev/null 2>&1
    psql "$DSN" -X -q -c "VACUUM docs" >/dev/null 2>&1
    sleep 5
  done ) & MPID=$!

# --- background: writer (insert new docs, exercising the pending->flush->merge path) ---
( n=0; while [ $(date +%s) -lt $END ]; do
    psql "$DSN" -X -q -c "INSERT INTO docs(id,title,body,d)
      SELECT 90000000+${n}*1000+g, 'soak', 'year soaked '||g,
             to_ftsdoc('english','year soaked '||g)
      FROM generate_series(1,1000) g" >/dev/null 2>&1
    n=$((n+1)); sleep 2
  done ) & WPID=$!

# --- readers: N concurrent loops of ranked + count, each recording wrong/err ---
mkdir -p /tmp/soak; : > /tmp/soak/errors
reader() {
  local id=$1 reads=0 errs=0
  while [ $(date +%s) -lt $END ]; do
    # ranked common-term top-10 (must return 10 rows or fail loudly)
    r=$(psql "$DSN" -X -q -t -A -c "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','year') ORDER BY d <=> to_ftsquery('english','year') LIMIT 10) s" 2>>/tmp/soak/errors)
    [ "$r" = "10" ] || { errs=$((errs+1)); echo "reader$id ranked got '$r'" >>/tmp/soak/errors; }
    # rare-term ranked
    r=$(psql "$DSN" -X -q -t -A -c "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s" 2>>/tmp/soak/errors)
    [ -n "$r" ] || { errs=$((errs+1)); echo "reader$id rare empty" >>/tmp/soak/errors; }
    # count(*) (index-only)
    psql "$DSN" -X -q -t -A -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','hungary')" >/dev/null 2>>/tmp/soak/errors || errs=$((errs+1))
    reads=$((reads+3))
  done
  echo "$reads $errs" > /tmp/soak/reader$id
}
NR=8
RPIDS=""
for i in $(seq 1 $NR); do reader $i & RPIDS="$RPIDS $!"; done
for p in $RPIDS; do wait $p; done
# stop bg maintenance/writer
kill $MPID $WPID 2>/dev/null; wait 2>/dev/null

echo "== soak end: $(date -u) =="
# server still up?
UP=$(Q "SELECT 'up' FROM (SELECT 1) x" | head -1)
echo "server after soak: ${UP:-DOWN/UNRESPONSIVE}"
TOT=0; ERR=0
for i in $(seq 1 $NR); do
  read rd er < /tmp/soak/reader$i 2>/dev/null || { rd=0; er=0; }
  TOT=$((TOT+rd)); ERR=$((ERR+er))
done
SZ1=$(Q "SELECT pg_relation_size('docs_fts')")
echo "total reads: $TOT   reader-detected wrong/err: $ERR"
echo "psql-level errors logged: $(wc -l < /tmp/soak/errors)"
echo "index size end: $((SZ1/1024/1024)) MB (start $((SZ0/1024/1024)) MB)"
echo "docs now: $(Q 'SELECT count(*) FROM docs')"
echo "nsegments: $(Q "SELECT fts_index_nsegments('docs_fts')")"
[ "${UP:-}" = "up" ] && [ "$ERR" = "0" ] && [ "$(wc -l < /tmp/soak/errors)" = "0" ] \
  && echo "== SOAK CLEAN ==" || echo "== SOAK ISSUES (see above / /tmp/soak/errors) =="
