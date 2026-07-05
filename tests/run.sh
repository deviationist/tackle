#!/usr/bin/env bash
# Run the full tackle test suite: the bats behavioral suite (bash) + a zsh smoke
# test. Usage: tests/run.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found — install with: brew install bats-core" >&2
  exit 127
fi

echo "== bats suite (bash) =="
bats "$here/tackle.bats"

echo
echo "== zsh smoke test =="
if command -v zsh >/dev/null 2>&1; then
  zsh "$here/tackle_zsh_smoke.sh"
else
  echo "zsh not found — skipping"
fi
