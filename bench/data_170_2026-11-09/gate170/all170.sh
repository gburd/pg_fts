#!/bin/bash
# all170.sh: the full 1.17.0 gate: old-arm build (v1.16.0 PGXN zip, sha256 591c2f8f...) -> main gate ->
# upgrade -> ASan (CI step extracted from ci.yml) -> per-commit (every commit v1.16.0..release, PG18 installcheck)
# -> nix flake (6 checks: installcheck/tap pg17/18 + tap-hooks pg17/18) -> 2 nix installcheck-pg17 --rebuild reruns.
# Every stage reports rc; GATE_SUMMARY lines at the end.  Inputs in /nvme/g170: final.tgz, c-<sha>.tgz,
# commits.txt, r170.bundle, pg_fts-1.16.0.zip.
G=/nvme/g170; cd $G
S=$(sha256sum pg_fts-1.16.0.zip | cut -c1-64)
[ "$S" = 591c2f8fd836c63f13c2c4e0ffec51709406c9276dae1493f454094f4ad2f2db ] || { echo "OLD ZIP SHA MISMATCH $S"; exit 1; }
for M in 17 18; do
  O=$G/old$M; [ -d $O ] || cp -a /nvme/pg$M $O
  OS=$G/oldsrc$M; [ -d $OS ] && mv $OS /nvme/trash_o_$RANDOM; mkdir -p $OS; (cd $OS && unzip -q $G/pg_fts-1.16.0.zip && cd pg_fts-1.16.0 && make -s -j32 PG_CONFIG=$O/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$O/bin/pg_config >/dev/null 2>&1) || { echo "OLD BUILD FAIL PG$M"; exit 1; }
  echo "old arm PG$M: $(grep default_version $OS/pg_fts-1.16.0/pg_fts.control) so=$(md5sum $O/lib/postgresql/pg_fts.so | cut -c1-8)"
done
echo "tree $(tar xzf $G/final.tgz -O ./GITREV); commits: $(cat $G/commits.txt | tr '\n' ' ')"
bash /tmp/g2/gate170.sh; echo "GATE_SUMMARY main rc=$? $(grep -E 'installcheck rc|summary:|tap rc|hooks tap rc|^Result|check-alloc|check-ascii|docs:|fuzz rc|ALL CLEAN|coverage rc|rerun|oom' $G/gate170.log | tr '\n' ' ')"
bash /tmp/g2/upg170.sh; echo "GATE_SUMMARY upgrade $(grep -c 'UPGRADE OK' $G/upg170.log) of 2 UPGRADE OK"
bash /tmp/g2/asan170.sh; echo "GATE_SUMMARY asan rc=$?"
COMMITS="$(cat $G/commits.txt)" bash /tmp/g2/percommit170.sh; echo "GATE_SUMMARY percommit rc=$? $(grep -cE ' rc=0 ' $G/percommit170.log) green"
bash /tmp/g2/nixgate170.sh $G/r170.bundle final > $G/nix170.log 2>&1; echo "GATE_SUMMARY nix rc=$? $(grep -E '^nix build rc' $G/nix170.log)"
. ~/.nix-profile/etc/profile.d/nix.sh
cd /nvme/nixgate-final && echo "nix tree $(git log -1 --format=%h)"
for i in 1 2; do
  nix --extra-experimental-features "nix-command flakes" build .#checks.$(uname -m)-linux.installcheck-pg17 -L --no-link > $G/nixrep17-$i.log 2>&1
  echo "GATE_SUMMARY nix pg17 rerun $i rc=$? $(grep -E 'tests (passed|failed)' $G/nixrep17-$i.log | sed 's/.*> //' | tr '\n' ' ')"
done
echo ALL170_DONE
