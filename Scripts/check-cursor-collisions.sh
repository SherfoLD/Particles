#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/cursor-checks
swift build -c release

# Sequential runs: no competing GPU work, identical settled-pile starting state.
.build/release/Particles --render-benchmark --settled-pile-fixture \
  --count 10000 --frames 1440 --require-120fps > build/cursor-checks/disabled-pile.json
.build/release/Particles --render-benchmark --settled-pile-fixture --cursor-fixture \
  --count 10000 --frames 1440 --require-120fps > build/cursor-checks/enabled-pile.json
.build/release/Particles --render-benchmark --window-fixtures --cursor-fixture \
  --count 10000 --frames 1440 --ball-speed 500 --require-120fps > build/cursor-checks/enabled-windows.json
.build/release/Particles --render-benchmark --settled-pile-fixture --cursor-fixture \
  --cpu-physics --count 3000 --frames 960 > build/cursor-checks/cpu-pile.json
printf 'Cursor performance checks passed. Reports: build/cursor-checks/\n'
