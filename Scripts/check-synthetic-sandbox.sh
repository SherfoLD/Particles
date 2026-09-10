#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/synthetic-checks
swift build -c release
result=0
# Uninstrumented timing gate; geometry scheduling is included in frame time.
.build/release/Particles --render-benchmark --scenario Scenarios/lift-window.json \
  --count 3000 --require-120fps > build/synthetic-checks/lift-window.json || result=1
# Separate diagnostic run: JSONL includes source/collision bounds on every frame.
.build/release/Particles --render-benchmark --scenario Scenarios/lift-window.json \
  --count 10000 --profile-physics --sandbox-log build/synthetic-checks/lift-window.jsonl \
  > build/synthetic-checks/lift-window-10000.json || result=1
if (( result == 0 )); then
  printf 'Synthetic checks passed. Reports: build/synthetic-checks/\n'
else
  printf 'Synthetic checks failed. Reports: build/synthetic-checks/\n' >&2
fi
exit "$result"
