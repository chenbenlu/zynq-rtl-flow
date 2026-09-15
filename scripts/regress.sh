#!/usr/bin/env bash
# Full local regression: script tests -> lint -> simulate -> coverage.
# Mirrors what CI runs, so a green regress.sh should mean a green pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> [1/4] Script tests"
make test-scripts

echo "==> [2/4] Lint"
make lint

echo "==> [3/4] Simulate"
make sim

echo "==> [4/4] Coverage"
make coverage

echo "Regression complete."
