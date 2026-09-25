#!/usr/bin/env bash
# No-neural parity against main: a base/puller/rusher lineup must reach the
# final state hash that main's headless binary reached for the same seed
# (tests/gota_golden.txt, recorded from main). Neural support must not move
# a match without neural seats by a single bit.
#   bash tests/gota_golden.sh
set -euo pipefail
P=examples/gods_of_the_arena/players
nim c --hints:off -d:release -d:headless -o:tmp/gota_golden examples/gods_of_the_arena/gota.nim
status=0
while read -r seed ticks want; do
  [[ -z "$seed" || "$seed" == \#* ]] && continue
  got=$(tmp/gota_golden --bot $P/base.bas:4 --bot $P/puller.bas:3 --bot $P/rusher.bas:3 \
    --seed "$seed" --ticks "$ticks" | grep -o 'hash: [0-9A-Fa-f]*' | tail -1 | awk '{print tolower($2)}')
  if [[ "$got" == "$want" ]]; then echo "PASS seed $seed ticks $ticks hash $got"
  else echo "FAIL seed $seed ticks $ticks hash $got, main reached $want"; status=1; fi
done < tests/gota_golden.txt
exit $status
