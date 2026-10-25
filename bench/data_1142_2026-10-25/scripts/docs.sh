#!/bin/bash
which xsltproc >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xsltproc docbook-xsl-ns >/dev/null 2>&1
T=/nvme/fp/doctree; [ -d $T ] && mv $T /nvme/trash_$RANDOM; mkdir -p $T && cd $T && git clone -q -b fix1142 /nvme/fp/r1142full.bundle . && git log -1 --format="%h %s"
bash doc/build-html.sh 2>&1 | tail -3
echo "upgrade section in html: $(grep -c 'Upgrading an index written by 1.10.0' doc/html/pg_fts.html)"
