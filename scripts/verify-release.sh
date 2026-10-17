#!/usr/bin/env bash
set -euo pipefail

version="${1:-v1.0.0}"

git fetch --force --tags origin main production

head_sha="$(git rev-parse HEAD)"
main_sha="$(git rev-parse origin/main)"
production_sha="$(git rev-parse origin/production)"
tag_sha="$(git rev-list -n 1 "$version")"
tag_type="$(git cat-file -t "$version")"

if [[ "$tag_type" != "tag" ]]; then
  echo "$version must be an annotated tag" >&2
  exit 1
fi

if [[ "$head_sha" != "$main_sha" || "$main_sha" != "$production_sha" || "$main_sha" != "$tag_sha" ]]; then
  printf 'Release refs diverged: HEAD=%s main=%s production=%s tag=%s\n' \
    "$head_sha" "$main_sha" "$production_sha" "$tag_sha" >&2
  exit 1
fi

echo "Release refs converge on $head_sha"
