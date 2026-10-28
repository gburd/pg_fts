#!/bin/bash
# vpexp.sh: does an open snapshot held by another backend flip vacuum_parallel's serial_reclaims to f?
# arms: none (control) / holder (REPEATABLE READ snapshot open across the whole test); 3 runs each, PG17 fix build
P=/nvme/iss/pg17-fix/bin; D=/nvme/iss/d17-fix; PORT=5817; O=/nvme/iss/vpexp; mkdir -p $O
$P/pg_ctl -D $D -l $D/log -w start >/dev/null 2>&1
Q="$P/psql -X -q -h /tmp -p $PORT -U postgres"
for arm in none holder none holder none holder; do
  $P/dropdb -h /tmp -p $PORT -U postgres --if-exists vpx >/dev/null 2>&1; $P/createdb -h /tmp -p $PORT -U postgres vpx
  $Q -d vpx -c "CREATE EXTENSION pg_fts" >/dev/null
  HP=
  if [ $arm = holder ]; then
    $Q -d postgres -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM pg_class; SELECT pg_sleep(600); COMMIT" >/dev/null 2>&1 &
    HP=$!; sleep 1
    echo "holder backend_xmin: $($Q -At -d postgres -c "SELECT backend_xmin FROM pg_stat_activity WHERE query LIKE '%pg_sleep(600)%' AND pid <> pg_backend_pid()")"
  fi
  $Q -d vpx -f /tmp/vp.sql > $O/$arm.$RANDOM.out 2>&1
  R=$(ls -t $O/$arm.*.out | head -1)
  echo "$arm: serial_reclaims=$(grep -A2 'serial_reclaims$' $R | tail -1 | tr -d ' ') parallel_no_growth=$(grep -A2 'parallel_no_growth$' $R | tail -1 | tr -d ' ') index_matches_heap_after=$(grep -A2 'index_matches_heap_after$' $R | tail -1 | tr -d ' ')"
  if [ -n "$HP" ]; then $Q -At -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(600)%' AND pid <> pg_backend_pid()" >/dev/null; wait $HP 2>/dev/null; fi
done
$P/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1
echo VPEXP_DONE
