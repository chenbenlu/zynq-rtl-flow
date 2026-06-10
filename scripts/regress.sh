#!/usr/bin/env bash
# Full local regression: lint -> simulate -> coverage.
# Mirrors what CI runs, so a green regress.sh should mean a green pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> [1/3] Lint"
make lint

echo "==> [2/3] Simulate"
make sim

echo "==> [3/3] Coverage"
make coverage

echo "Regression complete."
