#!/bin/bash
# vpexp2.sh: the 1.14.3 vacuum_parallel (waits for other snapshots) vs its expected file, pg_regress-style (psql -X -a -q),
# PG17 and PG18 fix builds; arms: none / short (snapshot held 20 s, must pass) / long (held 300 s, must still fail: bound)
O=/nvme/iss/vpexp2; mkdir -p $O
for M in 17 18; do
  P=/nvme/iss/pg$M-fix/bin; D=/nvme/iss/d$M-fix; PORT=58$M
  $P/pg_ctl -D $D -l $D/log -w start >/dev/null 2>&1
  Q="$P/psql -X -q -h /tmp -p $PORT -U postgres"
  for arm in none short none short long; do
    $P/dropdb -h /tmp -p $PORT -U postgres --if-exists vpx >/dev/null 2>&1; $P/createdb -h /tmp -p $PORT -U postgres vpx
    $Q -d vpx -c "CREATE EXTENSION pg_fts" >/dev/null
    HP=; S=0; [ $arm = short ] && S=20; [ $arm = long ] && S=300
    if [ $S -gt 0 ]; then
      $Q -d postgres -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM pg_class; SELECT pg_sleep($S); COMMIT" >/dev/null 2>&1 & HP=$!; sleep 1
    fi
    t0=$(date +%s.%N)
    $P/psql -X -a -q -h /tmp -p $PORT -U postgres -d vpx < /tmp/vp2.sql > $O/$M-$arm.out 2>&1
    t1=$(date +%s.%N)
    nd=$(diff /tmp/vp2.out.expected $O/$M-$arm.out | grep -c '^[<>]')
    echo "PG$M $arm: diff_lines=$nd serial_reclaims=$(grep -A2 '^ serial_reclaims *$' $O/$M-$arm.out | tail -1 | tr -d ' ') secs=$(echo "$t1 - $t0" | bc)"
    [ $nd -gt 0 ] && diff /tmp/vp2.out.expected $O/$M-$arm.out | head -12
    if [ -n "$HP" ]; then $Q -At -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep($S)%' AND pid <> pg_backend_pid()" >/dev/null; wait $HP 2>/dev/null; fi
  done
  $P/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1
done
echo VPEXP2_DONE
