#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/particle-checks
swift build -c release
.build/release/Particles --cannon-placement-benchmark --require-120fps \
  > build/particle-checks/cannon-placement.json
.build/release/Particles --render-benchmark --cannon-fixture --window-fixtures --frames 3600 --require-120fps \
  > build/particle-checks/metal-cannon-windows.json
.build/release/Particles --benchmark --frames 1440 > build/particle-checks/physics.json
.build/release/Particles --render-benchmark --frames 1440 --require-120fps \
  --snapshot build/particle-checks/particles.png > build/particle-checks/metal.json
.build/release/Particles --render-benchmark --window-fixtures --frames 1440 --require-120fps \
  > build/particle-checks/metal-windows.json
.build/release/Particles --render-benchmark --window-fixtures --count 10000 --frames 1440 --require-120fps \
  > build/particle-checks/metal-10000-windows.json
.build/release/Particles --render-benchmark --settled-pile-fixture --count 10000 --frames 1440 --require-120fps \
  > build/particle-checks/metal-settled-pile.json
.build/release/Particles --render-benchmark --pile-drag-fixture --count 10000 --frames 1440 --require-120fps \
  > build/particle-checks/metal-pile-drag.json
.build/release/Particles --render-benchmark --pile-drag-fixture --count 10000 --frames 1440 \
  --drag-hz 4 --window-poll-hz 30 --require-120fps > build/particle-checks/metal-fast-pile-drag.json
.build/release/Particles --render-benchmark --squeeze-fixture --count 10000 --frames 1440 --require-120fps \
  > build/particle-checks/metal-squeeze.json
.build/release/Particles --render-benchmark --compressed-pile-fixture --count 10000 --frames 720 --require-120fps \
  > build/particle-checks/metal-coincident-pile.json
if [[ "${1:-}" == "--window" ]]; then
  .build/release/Particles --sandbox --window-fixtures --count 10000 --duration 20 > build/particle-checks/window.json
fi
printf 'Particle checks passed. Reports: build/particle-checks/\n'
