#!/usr/bin/env bash
# Create the stage branches Kargo-delivered environments read from, for any
# that do not exist yet, with the current rendered values. A new environment
# then stands up from the repo alone; Kargo takes over with the first
# promotion.
#
#   scripts/seed-stage-branches.sh <services checkout> <push URL>
set -euo pipefail
root=$1 url=$2
existing=$(git ls-remote --heads "$url" 'stage/*' | awk '{print $2}' | sed 's|refs/heads/||')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for app in "$root"/apps/*/*.yaml; do
  branch=$(yq 'select(.kind == "Application") | .spec.sources[] | select(.ref == "values") | .targetRevision' "$app")
  [[ $branch == stage/* ]] || continue
  if grep -qx "$branch" <<<"$existing"; then continue; fi
  env=$(yq '.metadata.labels["platform.mcafeelabs.io/env"]' "$app")
  svc=$(yq '.metadata.labels["platform.mcafeelabs.io/service"]' "$app")
  rm -rf "$tmp/b" && mkdir "$tmp/b"
  cp "$root/rendered/$env/$svc/values.yaml" "$tmp/b/values.yaml"
  git -C "$tmp/b" init -q -b "$branch"
  git -C "$tmp/b" add values.yaml
  git -C "$tmp/b" -c user.name=svcreg -c user.email=svcreg@users.noreply.github.com commit -qm "seed $branch"
  git -C "$tmp/b" push -q "$url" "HEAD:refs/heads/$branch"
  echo "seeded $branch"
done
