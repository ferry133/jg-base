#!/usr/bin/env bash
# Bump the base `im` claude-code image pin (tag@digest) in one shot. Run AFTER
# k8scc main is pushed and its CI has built ghcr.io/ferry133/claude-code:<sha>
# (tag = commit short sha, see k8scc .github/workflows).
#
# tag@digest and not a bare tag, and not `latest`: #66 measured `latest`
# frozen on spegel clusters (the mirror answers tag queries from node cache,
# so jg-jiahd ran a months-old image while every signal read green). The
# digest is resolved from GHCR here, at bump time, so what lands in git is
# exactly what every cluster will run.
#
# Usage:
#   scripts/bump-claudecode-image.sh <new-short-sha>
#   # get the sha after merging k8scc:
#   #   git -C /path/to/k8scc rev-parse --short=7 HEAD
#
# Then review `git diff` and commit/push to let Flux reconcile (<=1h).
set -euo pipefail

NEWSHA="${1:-}"
if [[ -z "$NEWSHA" ]]; then
  echo "usage: $0 <new-short-sha>" >&2
  exit 1
fi
if [[ ! "$NEWSHA" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "error: '$NEWSHA' doesn't look like a git sha" >&2
  exit 1
fi

# Resolve the digest for this tag from GHCR. Asking the registry (not a
# cluster, not a mirror) is the point: this is the one place a mutable-tag
# answer cannot have been frozen by spegel.
DIGEST="$(gh api "users/ferry133/packages/container/claude-code/versions?per_page=50" \
  --jq ".[] | select(.metadata.container.tags | index(\"${NEWSHA}\")) | .name" | head -1)"
if [[ ! "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "error: GHCR has no image tagged '${NEWSHA}' (is the k8scc CI build done?)" >&2
  exit 1
fi
PIN="${NEWSHA}@${DIGEST}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/kubernetes/apps/base/claudecode/claude-code/im/enabled/helmrelease.yaml"
[[ -f "$F" ]] || { echo "missing: $F" >&2; exit 1; }

# The pin goes in via the environment and the `e` modifier concatenates it,
# because a double-quoted perl replacement would interpolate `@sha256` as an
# (empty) perl array — measured: the first version of this script wrote
# `tag: <sha>:<digest>` and only the site-count guard below caught it.
PIN="$PIN" perl -pi -e 's{^(\s*tag: )[\w.-]+\@sha256:[0-9a-f]{64}$}{$1 . $ENV{PIN}}ge' "$F"

n=$(grep -c "tag: ${PIN}" "$F" || true)
if [[ "$n" -ne 3 ]]; then
  echo "error: expected 3 pinned image sites in $F, found ${n} after rewrite" >&2
  echo "       (app, talos-mcp, oauth2-emails init — did the file change shape?)" >&2
  exit 1
fi
echo "pinned 3 sites to ${PIN}"
echo "review: git diff — then commit and push"
