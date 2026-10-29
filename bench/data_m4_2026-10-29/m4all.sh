#!/bin/bash
# M4 full run: prep -> base -> each engine (fts first: our arm; then the published set) -> M4ALL_DONE
bash /tmp/m4/m4.sh prep && bash /tmp/m4/m4.sh base || { echo PREP_OR_BASE_FAIL; exit 1; }
for e in fts pdb pgts gin; do bash /tmp/m4/m4.sh engine $e; done
echo M4ALL_DONE
