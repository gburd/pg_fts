#!/bin/bash
# m4fix.sh: (1) the corpus' long posts through to_ftsdoc('english') on 5a01219 (installed), the 1.15.0 release zip and
# 1.15.1 (057fcc5): errors and >16,383-position counts; (2) pg_fts engine on 1.15.1 (64 GB build); (3) GIN W2 rerun.
exec > /nvme/m4/m4fix.log 2>&1
PG=/nvme/pg18; B=$PG/bin; W=/nvme/m4
. /dev/null
D=$W/d_fts
sudo systemctl stop pg-m4 >/dev/null 2>&1; sudo systemctl reset-failed pg-m4 >/dev/null 2>&1
sudo systemd-run --unit=pg-m4 --uid=admin --gid=admin -p AllowedCPUs=0-7 -p MemoryMax=64G $B/postgres -D $D >/dev/null 2>&1
for i in $(seq 120); do $B/pg_isready -h /tmp -p 6500 -q && break; sleep 1; done
P="$B/psql -X -q -At -h /tmp -p 6500 -U postgres -d m4"
$P -c "DROP TABLE IF EXISTS longp" -c "CREATE TABLE longp AS SELECT id, content FROM posts WHERE octet_length(content) > 60000"
echo "long posts (> 60 kB): $($P -c 'select count(*) from longp'), non-ASCII among them: $($P -c "select count(*) from longp where content ~ '[^\x01-\x7f]'")"
probe() {
  $P -c "CREATE EXTENSION IF NOT EXISTS pg_fts" -c "SET client_min_messages = warning" -c "DO \$\$
DECLARE r record; n int; errs int := 0; over int := 0; tot int := 0; firsterr text;
BEGIN
  FOR r IN SELECT id, content FROM longp ORDER BY id LOOP
    BEGIN
      n := ftsdoc_length(to_ftsdoc('english', r.content)); tot := tot + 1;
      IF n > 16383 THEN over := over + 1; END IF;
    EXCEPTION WHEN OTHERS THEN errs := errs + 1; IF firsterr IS NULL THEN firsterr := r.id || ': ' || SQLERRM; END IF;
    END;
  END LOOP;
  RAISE NOTICE 'ok=% over16383=% errors=% first=%', tot, over, errs, coalesce(firsterr, '-');
END \$\$" 2>&1 | grep -oE "ok=.*"
}
inst() {  # inst <label> <source dir>
  (cd $2 && make -s clean PG_CONFIG=$B/pg_config >/dev/null 2>&1; make -s -j16 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)
  sudo systemctl stop pg-m4; sudo systemctl reset-failed pg-m4 >/dev/null 2>&1
  sudo systemd-run --unit=pg-m4 --uid=admin --gid=admin -p AllowedCPUs=0-7 -p MemoryMax=64G $B/postgres -D $D >/dev/null 2>&1
  for i in $(seq 120); do $B/pg_isready -h /tmp -p 6500 -q && break; sleep 1; done
  echo "== $1: so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) $(grep default_version $2/pg_fts.control) $(cat $2/GITREV 2>/dev/null)"
  probe
}
inst 5a01219 /nvme/m4/ftssrc
mkdir -p $W/z150 && cd $W/z150 && { [ -f pg_fts-1.15.0.zip ] || curl -sfLO https://api.pgxn.org/dist/pg_fts/1.15.0/pg_fts-1.15.0.zip; } && unzip -oq pg_fts-1.15.0.zip
echo "1.15.0 zip sha256 $(sha256sum $W/z150/pg_fts-1.15.0.zip | cut -c1-16)"
inst v1.15.0 $W/z150/pg_fts-1.15.0
S=$W/src151; [ -d $S ] && mv $S /nvme/trash_m4_$RANDOM; mkdir -p $S; tar xzf $W/r151.tgz -C $S
inst 1.15.1-rc $S
$P -c "DROP TABLE longp" -c "DROP EXTENSION pg_fts"
sudo systemctl stop pg-m4; sudo systemctl reset-failed pg-m4 >/dev/null 2>&1
echo "== engine fts on 1.15.1-rc"
bash /tmp/m4/m4.sh engine fts; echo "engine fts rc=$?"
echo "== gin W2 rerun (server restarted)"
bash /tmp/m4/m4.sh workloads gin W2
echo M4FIX_DONE
