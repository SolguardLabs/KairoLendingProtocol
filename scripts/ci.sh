#!/usr/bin/env bash
set -euo pipefail

FORGE="$(bash scripts/find-forge.sh)"

bash scripts/bootstrap.sh
"$FORGE" fmt --check
"$FORGE" build
FOUNDRY_PROFILE=ci "$FORGE" test
bash scripts/check-loc.sh
