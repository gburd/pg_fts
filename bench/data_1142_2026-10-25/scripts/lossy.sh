#!/bin/bash
X=pg18-upgC; N=C1; P=5492
bash /tmp/pgc.sh $X $N $P start >/dev/null 2>&1
/nvme/fp/$X/bin/psql -h /tmp -p $P -U postgres -X postgres -f /tmp/lossy.sql 2>&1 | grep -vE '^$'
bash /tmp/pgc.sh $X $N $P stop >/dev/null 2>&1
echo LOSSY_DONE
