#!/bin/bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lcov >/dev/null 2>&1
G=/nvme/g160; CT=$G/covtree2; [ -d $CT ] && mv $CT /nvme/trash_g_$RANDOM; mkdir -p $CT; tar xzf $G/final.tgz -C $CT; cd $CT
CP=$G/pfxcov; [ -d $CP ] || cp -a /nvme/pg17 $CP
COV_MIN=90 COV_CORPUS=1 PG_CONFIG=$CP/bin/pg_config PGBIN=$CP/bin bash ci/coverage.sh > $G/cov2.log 2>&1; echo "coverage rc=$?"; grep -iE "lines|functions|branches|gate|PASS|FAIL" $G/cov2.log | tail -6
