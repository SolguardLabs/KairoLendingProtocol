#!/usr/bin/env bash
set -euo pipefail

FORGE="$(bash scripts/find-forge.sh)"

if [[ ! -f lib/forge-std/src/Test.sol ]]; then
  "$FORGE" install foundry-rs/forge-std@v1.16.2 --no-git --shallow
fi
