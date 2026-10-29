#!/bin/bash
# walcc.sh -- ROADMAP I3 (vanilla half): every GenericXLog record pg_fts writes, replayed and compared byte-for-byte.
# Primary with wal_consistency_checking = 'generic' (+ full_page_writes): each generic record carries a full-page image,
# and the hot standby, after redo, compares its page to that image and FATALs on any difference ("inconsistent page
# found").  Workload on the primary: the whole installcheck suite (30 regress + 4 isolation) and TAP-like churn
# (deletes, VACUUM, fts_merge, pending flushes, fts_vacuum).  Then the standby is checked: replay caught up, no FATAL,
# and its index answers == heap on a sample of terms.  PG 17.10 and 18.6.  Log /nvme/walcc/walcc.log.
set -uo pipefail
O=/nvme/walcc; mkdir -p $O; exec > $O/walcc.log 2>&1
for M in 17 18; do
  B=/nvme/g150/pfx$M/bin; PP=581$M; SP=582$M
  P=$O/p$M; S=$O/s$M
  for d in $P $S; do $B/pg_ctl -D $d -m immediate -w stop >/dev/null 2>&1; [ -d $d ] && mv $d /nvme/trash_wc_$RANDOM; done
  $B/initdb -D $P -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PP\nunix_socket_directories='/tmp'\nlisten_addresses=''\nwal_level=replica\nwal_consistency_checking='generic'\nmax_wal_senders=4\nhot_standby=on\nmax_worker_processes=16\nshared_buffers=256MB\nmax_wal_size=8GB\n" >> $P/postgresql.conf
  echo "local replication all trust" >> $P/pg_hba.conf
  $B/pg_ctl -D $P -l $P/log -w start >/dev/null
  $B/pg_basebackup -h /tmp -p $PP -U postgres -D $S -R -X stream >/dev/null 2>&1 || { echo "PG$M BASEBACKUP FAIL"; continue; }
  sed -i "s/^port=$PP/port=$SP/" $S/postgresql.conf
  $B/pg_ctl -D $S -l $S/log -w start >/dev/null
  echo "== PG$M $($B/postgres --version): primary wal_consistency_checking=$($B/psql -X -At -h /tmp -p $PP -U postgres -c 'show wal_consistency_checking'), standby in recovery=$($B/psql -X -At -h /tmp -p $SP -U postgres -c 'select pg_is_in_recovery()')"
  cd /nvme/g150/gtree$M
  make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=$PP PGUSER=postgres PROVE_TESTS=ci/noop.pl > $O/ic$M.log 2>&1; echo "installcheck on primary rc=$? $(grep -cE '^ok ' $O/ic$M.log) ok $(grep -cE '^not ok ' $O/ic$M.log) not ok"
  Q="$B/psql -X -q -At -h /tmp -p $PP -U postgres -v ON_ERROR_STOP=1"
  $Q -c "CREATE DATABASE churn"; Q="$Q -d churn"
  $Q -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE t (id int PRIMARY KEY, body text, d ftsdoc)" \
     -c "INSERT INTO t SELECT g, 'alpha w' || (g % 97) || CASE WHEN g % 50 = 0 THEN ' rare' ELSE '' END || CASE WHEN g % 7 = 0 THEN ' alpha beta' ELSE '' END, NULL FROM generate_series(1, 200000) g" \
     -c "UPDATE t SET d = to_ftsdoc('simple', body)" \
     -c "CREATE INDEX t_d ON t USING fts (d) WITH (positions = on)" -c "CREATE INDEX t_e ON t USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = off)" \
     -c "VACUUM ANALYZE t" -c "DELETE FROM t WHERE id % 11 = 0" -c "VACUUM t" \
     -c "SET pg_fts.pending_flush_threshold = 300" -c "INSERT INTO t SELECT g, 'fresh rare alpha beta', to_ftsdoc('simple', 'fresh rare alpha beta') FROM generate_series(200001, 230000) g" \
     -c "SELECT fts_merge('t_d')" -c "SELECT fts_merge('t_e')" -c "DELETE FROM t WHERE id % 5 = 0" -c "VACUUM t" -c "SELECT fts_vacuum('t_d')" -c "SELECT fts_vacuum('t_e')" >/dev/null
  echo "churn rc=$?"
  lsn=$($B/psql -X -At -h /tmp -p $PP -U postgres -c "SELECT pg_current_wal_insert_lsn()")
  for i in $(seq 1 600); do r=$($B/psql -X -At -h /tmp -p $SP -U postgres -c "SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn" 2>/dev/null); [ "$r" = t ] && break; sleep 1; done
  echo "standby replayed to $lsn: ${r:-no} (after ${i}s); standby up: $($B/pg_ctl -D $S status >/dev/null 2>&1 && echo yes || echo NO)"
  echo "standby log: FATAL/PANIC $(grep -cE 'FATAL|PANIC' $S/log), 'inconsistent page' $(grep -c 'inconsistent page' $S/log)"; grep -E "inconsistent page|PANIC|FATAL" $S/log | head -3
  SQ="$B/psql -X -q -At -h /tmp -p $SP -U postgres -d churn"
  bad=0; for q in "'rare'" "'alpha & w7'" "'\"alpha beta\"'" "'fresh'"; do
    h=$($SQ -c "SELECT count(*) FROM t WHERE fts_match(d, $q::ftsquery)"); i1=$($SQ -c "SET enable_seqscan=off" -c "SELECT count(*) FROM t WHERE d @@@ $q::ftsquery" | tail -1); i2=$($SQ -c "SET enable_seqscan=off" -c "SELECT count(*) FROM t WHERE to_ftsdoc('simple', body) @@@ $q::ftsquery" | tail -1)
    echo "  standby $q heap=$h idx=$i1 expr=$i2"; [ "$h" = "$i1" ] && [ "$h" = "$i2" ] && [ "$h" -gt 0 ] || bad=1
  done
  # the generic records actually carried images: count them in the WAL (pg_waldump --stats)
  echo "WAL generic records: $($B/pg_waldump -p $P/pg_wal --stats=record $(ls $P/pg_wal | grep -E '^[0-9A-F]{24}$' | head -1) 2>/dev/null | grep -E '^Generic' | head -3 | tr -s ' ' | tr '\n' ';')"
  echo "PG$M WALCC $([ $bad = 0 ] && [ "$(grep -c 'inconsistent page' $S/log)" = 0 ] && [ "${r:-}" = t ] && echo OK || echo FAIL)"
  $B/pg_ctl -D $S -m fast -w stop >/dev/null; $B/pg_ctl -D $P -m fast -w stop >/dev/null
done
echo WALCC_DONE
