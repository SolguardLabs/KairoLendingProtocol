#!/usr/bin/env bash
set -euo pipefail

pattern='(^|[^[:alnum:]_])(ctf|capture[[:space:]-]+the[[:space:]-]+flag|vulnerability|exploit)([^[:alnum:]_]|$)'
roots=(README.md SECURITY.md CHANGELOG.md CONTRIBUTING.md docs src test script scripts .github)

if grep -RIEin \
  --exclude='verify-public.sh' \
  --exclude-dir='.git' \
  --exclude-dir='lib' \
  --exclude-dir='out' \
  --exclude-dir='cache' \
  -- "$pattern" "${roots[@]}"; then
  echo "Public-surface policy rejected one or more internal-only terms" >&2
  exit 1
fi

if grep -RIEin \
  --exclude='verify-public.sh' \
  --exclude-dir='.git' \
  --exclude-dir='assets' \
  --exclude-dir='lib' \
  --exclude-dir='out' \
  --exclude-dir='cache' \
  -- '(PRIVATE KEY|BEGIN [A-Z ]+ PRIVATE KEY|mnemonic[[:space:]]*=)' .; then
  echo "Potential credential material detected" >&2
  exit 1
fi

echo "Public-surface validation passed"
