#!/bin/bash
# vpflake2.sh: the nix installcheck-pg18 failure on 9ddb4b4 was vacuum_parallel serial_reclaims=f (the I18 class).
# Valid reruns: nix installcheck-pg18 built fresh (it failed, so nothing is cached), then --rebuild twice if it passes;
# Debian PG18 REGRESS=vacuum_parallel with pg_fts loaded (--load-extension), 5 runs each on 9ddb4b4 and v1.15.0.
exec > /nvme/g151/vpflake2.log 2>&1
. ~/.nix-profile/etc/profile.d/nix.sh
cd /nvme/nixgate-final; echo "nix tree $(git log -1 --format=%h)"
nix --extra-experimental-features 'nix-command flakes' build .#checks.x86_64-linux.installcheck-pg18 -L --no-link > /nvme/g151/vp2nix18-0.log 2>&1
echo "nix pg18 fresh rc=$? $(grep -E 'tests (passed|failed)|not ok' /nvme/g151/vp2nix18-0.log | sed 's/.*> //' | tr '\n' ' ')"
for i in 1 2; do
  nix --extra-experimental-features 'nix-command flakes' build .#checks.x86_64-linux.installcheck-pg18 -L --no-link --rebuild > /nvme/g151/vp2nix18-$i.log 2>&1
  echo "nix pg18 rebuild $i rc=$? $(grep -E 'tests (passed|failed)|not ok|not valid' /nvme/g151/vp2nix18-$i.log | sed 's/.*> //' | tr '\n' ' ')"
done
for L in fix v150; do
  B=/nvme/g151/$([ $L = fix ] && echo pfx18 || echo old18)/bin
  T=$([ $L = fix ] && echo /nvme/g151/gtree18 || echo /nvme/g151/oldsrc18/pg_fts-1.15.0)
  D=/nvme/g151/vp_$L; $B/pg_ctl -D $D -m fast -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_vp_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=5918\nunix_socket_directories='/tmp'\nlisten_addresses=''\nmax_worker_processes=16\n" >> $D/postgresql.conf; $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  cd $T; for i in 1 2 3 4 5; do make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=5918 PGUSER=postgres REGRESS=vacuum_parallel ISOLATION= PROVE_TESTS=ci/noop.pl EXTRA_REGRESS_OPTS=--load-extension=pg_fts > /nvme/g151/vp2_${L}_$i.log 2>&1; echo "debian PG18 $L run $i: $(grep -E '^(ok|not ok)' /nvme/g151/vp2_${L}_$i.log | awk '{print $1,$2}') $(grep -c 'serial_reclaims' regression.diffs 2>/dev/null)"; done
  $B/pg_ctl -D $D -w stop >/dev/null
done
echo VPFLAKE2_DONE
