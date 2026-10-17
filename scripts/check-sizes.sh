#!/usr/bin/env bash
set -euo pipefail

FORGE="$(bash scripts/find-forge.sh)"

echo "Validating EIP-170 runtime sizes"
"$FORGE" build --sizes

echo "Runtime size validation passed"
