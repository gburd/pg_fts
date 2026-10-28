#!/bin/bash
# M2 cluster: PG 17.10 copy at /nvme/m2/pg with pg_fts (tree aa96db4 build) + pg_search 0.26.1 (deb), port 6417
set -uo pipefail
exec > /nvme/m2/db.log 2>&1
PFX=/nvme/m2/pg; [ -d $PFX ] || cp -a /nvme/pg17 $PFX; B=$PFX/bin
LIB=$($B/pg_config --pkglibdir); SHR=$($B/pg_config --sharedir)
T=/nvme/m2/src; [ -d $T ] && mv $T /nvme/trash_m2_$RANDOM; mkdir -p $T; tar xzf /nvme/rm/i17.tgz -C $T; cd $T
make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1 || { echo FTS_BUILD_FAIL; exit 1; }
echo "pg_fts tree $(cat GITREV) so=$(md5sum $LIB/pg_fts.so | cut -c1-8)"
if [ ! -f $LIB/vector.so ]; then
  cd /nvme/m2; [ -d pgvector ] || git clone -q --branch v0.8.7 https://github.com/pgvector/pgvector.git
  cd pgvector; make -s clean >/dev/null 2>&1; make -s PG_CONFIG=$B/pg_config -j16 >/nvme/m2/pgvector_build.log 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
  echo "pgvector $(git describe --tags) $(ls $LIB/vector.so)"
fi
X=/nvme/m2/deb; [ -d $X ] || { mkdir -p $X; dpkg-deb -x /nvme/m2/postgresql-17-pg-search_0.26.1-1PARADEDB-trixie_amd64.deb $X; }
dpkg-deb -I /nvme/m2/postgresql-17-pg-search_0.26.1-1PARADEDB-trixie_amd64.deb | grep -E "Package|Version|Depends"
find $X -name "*.so" -path "*postgresql/17/lib*" -exec cp {} $LIB/ \;
find $X -path "*postgresql/17/extension/*" -type f -exec cp {} $SHR/extension/ \;
ls $LIB | grep -i search
D=/nvme/m2/data; [ -d $D ] && { $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; mv $D /nvme/trash_m2_$RANDOM; }
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null
printf "port=6417\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=4GB\nmaintenance_work_mem=2GB\nshared_preload_libraries='pg_search'\njit=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null || { tail -5 $D/log; exit 1; }
for db in scifact nfcorpus; do
  $B/createdb -h /tmp -p 6417 -U postgres $db
  P="$B/psql -X -q -h /tmp -p 6417 -U postgres -d $db -v ON_ERROR_STOP=1"
  $P -c "CREATE EXTENSION pg_fts" -c "CREATE EXTENSION pg_search CASCADE" \
     -c "CREATE TABLE docs (id text PRIMARY KEY, title text, body text)" \
     -c "\\copy docs FROM '/nvme/m2/$db/docs.tsv' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\b')" \
     -c "ALTER TABLE docs ADD COLUMN d ftsdoc, ADD COLUMN ds ftsdoc, ADD COLUMN tsv tsvector" \
     -c "UPDATE docs SET d = to_ftsdoc('english', coalesce(title,'') || ' ' || coalesce(body,'')), ds = to_ftsdoc('simple', coalesce(title,'') || ' ' || coalesce(body,'')), tsv = to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))" \
     -c "CREATE INDEX docs_fts ON docs USING fts (d)" -c "CREATE INDEX docs_fts_s ON docs USING fts (ds)" \
     -c "CREATE INDEX docs_tsv ON docs USING gin (tsv)" \
     -c "CREATE INDEX docs_bm25 ON docs USING bm25 (id, title, body) WITH (key_field = 'id')" \
     -c "VACUUM ANALYZE docs"
  echo "$db rows=$($P -At -c 'select count(*) from docs') ext=$($P -At -c "select string_agg(extname||' '||extversion, ', ' order by extname) from pg_extension where extname in ('pg_fts','pg_search')")"
done
echo M2DB_DONE
