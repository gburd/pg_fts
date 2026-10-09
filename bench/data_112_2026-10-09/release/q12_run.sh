#!/bin/bash
# 1.12.0 aarch64 qualification on one host: PG 17.10 build, fuzz/regress/iso/TAP/coverage (gate_arm.sh),
# then churn (8 writers + readers + VACUUM/fts_merge, DUR=300) and race (8 inserters + fts_merge 0.2 s),
# all on the 1.12.0 tree.
set -uo pipefail
exec > /tmp/q12.log 2>&1
DEV=$(lsblk -dn -o NAME,SIZE | awk '$2=="884.8G"{print "/dev/"$1; exit}')
sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config perl bc unzip git python3-venv sysstat xfsprogs clang llvm lcov libipc-run-perl libtest-simple-perl >/dev/null
sudo mkfs.xfs -f $DEV >/dev/null; sudo mkdir -p /nvme; sudo mount $DEV /nvme; sudo chown admin /nvme
cd /nvme; curl -sfLO https://ftp.postgresql.org/pub/source/v17.10/postgresql-17.10.tar.bz2; tar xjf postgresql-17.10.tar.bz2
cd postgresql-17.10; ./configure --prefix=/nvme/pg17 --enable-tap-tests CFLAGS="-O2 -g -fno-omit-frame-pointer" >/nvme/cfg.log 2>&1
make -s -j16 >/nvme/mk.log 2>&1; make -s install >/dev/null
for c in pg_prewarm pg_buffercache fuzzystrmatch pageinspect; do (cd contrib/$c && make -s install >/dev/null); done
echo PG_DONE
B=/nvme/pg17/bin
$B/initdb -D /nvme/rg -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55432\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=256MB\n" >> /nvme/rg/postgresql.conf
bash /tmp/gate_arm.sh
echo GATE_DONE
for r in 1 2; do DUR=300 TAGN=q12_$r SRC=/nvme/fts_gate bash /tmp/churn111.sh 2>&1 | grep -E "^so|writers|readers|maintenance err|server log|\[|index size"; echo "hard errors: $(grep -cE 'could not read blocks|previous segment|beyond EOF|terminated by signal|corrupt' /nvme/churn_q12_$r/log)"; done
echo CHURN_DONE
for r in 1 2 3; do DUR=40 bash /tmp/race.sh q12r$r 2>&1 | tail -1; done
echo ALL_DONE
