#!/bin/bash
# i9cmp2.sh: documents over 16,383 tokens whose markup can straddle a 16,383-byte chunk boundary (the chunked path).
exec > /nvme/i9cmp2.log 2>&1
cat > /nvme/i9docs2.sql <<'SQL'
DROP TABLE IF EXISTS docs2;
CREATE TABLE docs2 AS
SELECT 1 AS id, 'html-tags' AS kind, string_agg('<a href="x' || g || '" class="c y z"> w' || g || ' v u t ', '') AS t FROM generate_series(1, 5000) g
UNION ALL SELECT 2, 'html-comments', string_agg('<!-- a comment with spaces ' || g || ' --> b' || g || ' c d e ', '') FROM generate_series(1, 5000) g
UNION ALL SELECT 3, 'script-style', string_agg('<script>var a' || g || ' = 1;</script> v' || g || ' w x y <style>.c{x:y}</style> ', '') FROM generate_series(1, 5000) g
UNION ALL SELECT 4, 'mixed-markup', string_agg(CASE g % 3 WHEN 0 THEN '<p class="a b">' WHEN 1 THEN '<!-- n o p -->' ELSE '</p>' END || ' word' || g || ' and ' || 'https://e.com/a b@c.org ', '') FROM generate_series(1, 9000) g;
SQL
for L in ours wide; do PORT=$([ $L = ours ] && echo 5601 || echo 5602); /nvme/pfx-$L/bin/pg_ctl -D /nvme/d-$L -l /nvme/d-$L/log -w start >/dev/null 2>&1; /nvme/pfx-$L/bin/psql -X -q -h /tmp -p $PORT -U postgres -d c -f /nvme/i9docs2.sql; done
for cfg in simple english; do
  echo "== config $cfg"
  for id in 1 2 3 4; do
    q="SELECT kind, length(t), ftsdoc_length(to_ftsdoc('$cfg', t)), md5(to_ftsdoc('$cfg', t)::text) FROM docs2 WHERE id = $id"
    a=$(/nvme/pfx-ours/bin/psql -X -At -h /tmp -p 5601 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    b=$(/nvme/pfx-wide/bin/psql -X -At -h /tmp -p 5602 -U postgres -d c -c "SET client_min_messages=warning" -c "$q" 2>&1 | tail -1)
    echo "  $id $([ "$a" = "$b" ] && echo SAME || echo DIFF) ours=[$a] wide=[$b]"
    if [ "$a" != "$b" ]; then
      for L in ours wide; do PORT=$([ $L = ours ] && echo 5601 || echo 5602); /nvme/pfx-$L/bin/psql -X -At -h /tmp -p $PORT -U postgres -d c -c "SELECT unnest(string_to_array(to_ftsdoc('$cfg', t)::text, ' ')) FROM docs2 WHERE id = $id" | sort > /nvme/i9cmp2_${cfg}_${id}_$L.txt; done
      echo "    lexeme entries: ours $(wc -l < /nvme/i9cmp2_${cfg}_${id}_ours.txt) wide $(wc -l < /nvme/i9cmp2_${cfg}_${id}_wide.txt); only-ours $(comm -23 /nvme/i9cmp2_${cfg}_${id}_ours.txt /nvme/i9cmp2_${cfg}_${id}_wide.txt | wc -l), only-wide $(comm -13 /nvme/i9cmp2_${cfg}_${id}_ours.txt /nvme/i9cmp2_${cfg}_${id}_wide.txt | wc -l); sample only-ours: $(comm -23 /nvme/i9cmp2_${cfg}_${id}_ours.txt /nvme/i9cmp2_${cfg}_${id}_wide.txt | head -3 | cut -c1-60 | tr '\n' ' ')"
    fi
  done
done
echo I9CMP2_DONE
