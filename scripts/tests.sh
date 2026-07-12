#!/usr/bin/env bash
set -euo pipefail

FORGE="$(bash scripts/find-forge.sh)"

bash scripts/bootstrap.sh
"$FORGE" test
