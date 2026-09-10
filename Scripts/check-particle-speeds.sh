#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/speed-checks
swift build -c release

# Sequential GPU runs keep timing comparisons free of competing benchmark work.
for radius in 1.5 3 4.5; do
  for speed in 100 300 500; do
    .build/release/Particles --render-benchmark --window-fixtures \
      --count 3000 --frames 1440 --ball-radius "$radius" --ball-speed "$speed" --require-120fps \
      > "build/speed-checks/rain-r${radius}-s${speed}.json"
    .build/release/Particles --render-benchmark --cannon-fixture --window-fixtures \
      --count 3000 --frames 3600 --ball-radius "$radius" --ball-speed "$speed" --require-120fps \
      > "build/speed-checks/cannon-r${radius}-s${speed}.json"
  done
done

.build/release/Particles --render-benchmark --window-fixtures --count 10000 \
  --frames 1440 --ball-speed 500 --require-120fps > build/speed-checks/stress-windows-500.json

for fixture in settled-pile pile-drag squeeze compressed-pile; do
  .build/release/Particles --render-benchmark "--${fixture}-fixture" \
    --count 10000 --frames 1440 --ball-speed 500 --drag-hz 4 --window-poll-hz 30 --require-120fps \
    > "build/speed-checks/stress-${fixture}-500.json"
done
printf 'Speed performance checks passed. Reports: build/speed-checks/\n'
