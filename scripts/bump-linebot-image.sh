#!/usr/bin/env bash
# Bump the linebot image tag (git short sha) across all workloads that share the
# ghcr.io/ferry133/linebot image, in one shot. Run AFTER the linebot code is
# committed + pushed and CI (build.yaml) has built ghcr.io/ferry133/linebot:<sha>
# (tag = commit short sha, see linebot .github/workflows/build.yaml).
#
# Intentionally does NOT touch linebot/app/migrate-contacts-job.yaml — that Job
# is immutable/completed and bumping it wedges the `linebot` kustomization.
#
# Usage:
#   scripts/bump-linebot-image.sh <new-short-sha>
#   # get the sha after committing linebot:
#   #   git -C /path/to/linebot rev-parse --short=7 HEAD
#
# Then review `git diff` and commit/push to let Flux reconcile.
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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/kubernetes/apps/extras/default"

FILES=(
  "$BASE/trello-notifier/app/cronjobs.yaml"
  "$BASE/linebot/app/deploy.yaml"
  "$BASE/linebot/app/admin.yaml"
)

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
  perl -pi -e "s{(ghcr\.io/ferry133/linebot:)[\w.-]+}{\${1}${NEWSHA}}g" "$f"
  n=$(grep -c "ghcr.io/ferry133/linebot:${NEWSHA}" "$f" || true)
  echo "bumped ${n}x  ${f#$ROOT/}"
done

echo
echo "done → review: git -C $ROOT diff"
echo "next:  run gateway/setup_richmenu.py --replace once, then commit + push (Flux reconcile)"
