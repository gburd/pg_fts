#!/bin/bash
# psql-based single-test runner to generate an expected file (prints results path)
# usage: regp.sh <pgbin> <tree> <test> ; output /nvme/<test>.out
B=$1; T=$2; t=$3; P=55497; D=/nvme/rgp; [ -d $D ] && mv $D $D.old.$$
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nlc_messages='C'\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null; $B/createdb -h /tmp -p $P -U postgres regression
[ "$t" != pg_fts ] && $B/psql -h /tmp -p $P -U postgres -X -q -d regression -c "CREATE EXTENSION pg_fts" >/dev/null
PGOPTIONS="-c intervalstyle=postgres_verbose -c datestyle=Postgres,MDY -c timezone=PST8PDT" $B/psql -h /tmp -p $P -U postgres -X -a -q -d regression -v HIDE_TABLEAM=on -v HIDE_TOAST_COMPRESSION=on < $T/sql/$t.sql > /nvme/$t.out 2>&1
$B/pg_ctl -D $D -w stop >/dev/null; diff $T/expected/$t.out /nvme/$t.out > /nvme/$t.diff; echo "$t: $(grep -c '^[<>]' /nvme/$t.diff) diff lines, $(grep -c ERROR /nvme/$t.out) ERRORs"
