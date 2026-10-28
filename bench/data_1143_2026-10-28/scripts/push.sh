# push.sh: re-tar the working tree (tracked + listed untracked), ship, rebuild "fix"
cd /home/gburd/ws/pg_fts
{ git ls-files; git ls-files --others sql expected; } | grep -v ^bench/ | sort -u > /tmp/kiwi/iss/files.txt
tar -czf /tmp/kiwi/iss_fix.tgz -T /tmp/kiwi/iss/files.txt
/tmp/kiwi/kscp iss /nvme/iss /tmp/kiwi/iss_fix.tgz && /tmp/kiwi/kssh iss 'bash /tmp/bld.sh /nvme/iss/iss_fix.tgz fix 58 2>&1 | grep -v md5sum'
