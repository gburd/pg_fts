#!/bin/bash
# M4 engines from the loaded base (prep + base done 16:24)
for e in fts pdb pgts gin; do bash /tmp/m4/m4.sh engine $e; echo "engine $e rc=$?"; done
echo M4ALL_DONE
