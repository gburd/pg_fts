#!/bin/bash
# Bug 2: the reporter's deterministic SQL on PG 18.6, wal_level=replica (default), default
# parallel settings.  Arms: BUILD tag -> RUN tag (restart on RUN binaries + ALTER EXTENSION UPDATE).
set -uo pipefail
R=/nvme/b3/repro; PORT=55621
cat > /tmp/bug2_load.sql <<'EOSQL'
CREATE EXTENSION pg_fts;
CREATE TABLE m (id int PRIMARY KEY, body text, a int, b text);
INSERT INTO m
  SELECT g,
         (SELECT string_agg('w' || ((g * 7 + i * 13) % 12) || (i % 5), ' ')
            FROM generate_series(1, 60) i),
         g % 1000, md5(g::text)
    FROM generate_series(1, 20000) g;
CREATE INDEX m_fts ON m USING fts (to_ftsdoc('english', body));
CREATE INDEX ON m (b);
CREATE INDEX ON m (a, b);
EOSQL
arm() {  # $1 build tag, $2 run tag
  local BT=$1 RT=$2 D=/nvme/b3/bug2-$1-$2
  $R/pg-$BT/bin/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_b2_$RANDOM
  $R/pg-$BT/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
  $R/pg-$BT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  local P="$R/pg-$BT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"
  $P -f /tmp/bug2_load.sql >/dev/null
  echo "== build $BT -> run $RT: built ext $($P -c "select extversion from pg_extension where extname='pg_fts'"), fts size $($P -c "select pg_relation_size('m_fts')/8192") blocks, wal_level $($P -c 'show wal_level'), sizes b=$($P -c "select pg_relation_size('m_b')/1024")kB ab=$($P -c "select pg_relation_size('m_a_b_idx')/1024")kB"
  if [ $BT != $RT ]; then
    $R/pg-$BT/bin/pg_ctl -D $D -m fast -w stop >/dev/null
    $R/pg-$RT/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
    P="$R/pg-$RT/bin/psql -h /tmp -p $PORT -U postgres -X -q -At"
    $P -c "ALTER EXTENSION pg_fts UPDATE"
    echo "   restarted on $RT binaries; ext now $($P -c "select extversion from pg_extension where extname='pg_fts'")"
  fi
  $P -c "DELETE FROM m WHERE id % 50 = 0"
  echo "   VACUUM m: $($P -v VERBOSITY=verbose -c 'VACUUM m' 2>&1 | tr '\n' ' ' | head -c 300; echo " rc=${PIPESTATUS[0]}")"
  echo "   relfrozenxid advanced? $($P -c "select age(relfrozenxid) from pg_class where relname='m'") ; fts size now $($P -c "select pg_relation_size('m_fts')/8192") blocks"
  $P -c "DELETE FROM m WHERE id % 50 = 1"
  echo "   VACUUM (PARALLEL 0) m: $($P -c 'VACUUM (PARALLEL 0) m' 2>&1 | head -c 200; echo "rc=${PIPESTATUS[0]}")"
  echo "   count check: idx=$($P -c "set enable_seqscan=off; select count(*) from m where to_ftsdoc('english',body) @@@ 'w30'::ftsquery") heap=$($P -c "select count(*) from m where fts_match(to_ftsdoc('english',body),'w30'::ftsquery)")"
  $R/pg-$RT/bin/pg_ctl -D $D -m fast -w stop >/dev/null
}
arm v100 v100
arm v100 v130
arm v100 v140
arm v100 fix
arm v130 v130
arm v140 v140
arm fix fix
echo BUG2_DONE
