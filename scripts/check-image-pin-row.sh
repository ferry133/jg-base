#!/usr/bin/env bash
# Assert what daily-check's IM IMAGE PIN row emits, per cluster state.
#
# ferry133/jg-base#66: `latest` on a spegel cluster froze silently — the pod
# restarted, kubelet said Pulled, the Deployment said Running, and it was a
# months-old image. The pin (#67) removes the freeze; check 23 guards the two
# ways the pin can rot (spec back on a mutable tag; running digest != pinned).
# The case that must not regress is `running-differs`: that is #66's shape,
# and every other signal on the report reads green through it.
#
# Sources the real block out of the ConfigMap rather than restating its logic
# — a copy here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-image-pin-row.sh   (exit 0 if every case matches)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for tool in yq jq; do
  command -v "$tool" >/dev/null || {
    echo "$tool required. CI installs yq pinned in the 'scripts' job of"
    echo ".github/workflows/flux-local.yaml; jq ships on the runner image."
    exit 1
  }
done
yq -r '.data."run-check.sh"' "$CM" > "$WORK/run-check.sh"

python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1])
s = (work / "run-check.sh").read_text()
try:
    start = s.index("# 23. base im image pin")
    end = s.index('echo "==> Compiling report"')
except ValueError:
    sys.exit("could not locate the im-pin block in run-check.sh — markers moved")
blk = s[start:end]
if "imageID" not in blk:
    sys.exit("located a block that never reads imageID — the running half of #66's guard is gone")
if "@sha256:" not in blk:
    sys.exit("located a block that never tests for @sha256: — the pin half is gone")
if "claude-code-im" not in blk:
    sys.exit("located a block that never checks the owning HR — it would ring on pre-handover clusters")
(work / "block.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

D1="sha256:$(printf 'a%.0s' $(seq 64))"
D2="sha256:$(printf 'b%.0s' $(seq 64))"
REPO="ghcr.io/ferry133/claude-code"

deploy_json() { # $1=owner-label  $2..=images
  local owner="$1"; shift
  local imgs="" i
  for i in "$@"; do imgs="${imgs}{\"name\":\"c\",\"image\":\"$i\"},"; done
  printf '{"metadata":{"labels":{"helm.toolkit.fluxcd.io/name":"%s"}},"spec":{"selector":{"matchLabels":{"app":"im"}},"template":{"spec":{"containers":[%s],"initContainers":[]}}}}' \
    "$owner" "${imgs%,}"
}
pods_json() { # $@=imageIDs
  local ids="" i
  for i in "$@"; do ids="${ids}{\"imageID\":\"$i\"},"; done
  printf '{"items":[{"status":{"containerStatuses":[%s],"initContainerStatuses":[]}}]}' "${ids%,}"
}

FAILED=0
declare -A SEEN=()

run() { # $1=label $2=deploy json (or ABSENT) $3=pods json $4=expected prefix
  local label="$1" deploy="$2" pods="$3" want="$4"
  OUT=""
  record() { OUT="[$1] $2${3:+ — $3}"; }
  kubectl() {
    case "$*" in
      *"get deploy im"*) [[ "$deploy" == "ABSENT" ]] && return 1; printf '%s' "$deploy" ;;
      *"get pods"*)      printf '%s' "$pods" ;;
      *) echo "UNEXPECTED kubectl: $*" >&2; return 1 ;;
    esac
  }
  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  unset -f kubectl record 2>/dev/null || true

  local got="${OUT:-<no row>}"
  local level="${got%%]*}"; level="${level#[}"
  SEEN["$label"]="$level"
  if [[ "$got" == "$want"* ]]; then
    printf 'PASS  %-18s -> %s\n' "$label" "${got:0:88}"
  else
    printf 'FAIL  %-18s -> %s\n        expected %s...\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

PINNED="$(deploy_json claude-code-im "$REPO:9418571@$D1" "$REPO:9418571@$D1" "$REPO:9418571@$D1")"

# Absent and pre-handover are real states: they must not ring daily, and they
# must not render as a green row either — skip is the third outcome, and
# folding "could not measure" into "pass" is #66's own shape.
run absent        ABSENT   '{}'                     "[skip] im image pin — no im deployment"
run pre-handover  "$(deploy_json im "$REPO:9418571")" '{}' "[skip] im image pin — im owned by 'im', pre-handover"

# The spec quietly back on a mutable tag: the freeze risk returns. warn.
run unpinned      "$(deploy_json claude-code-im "$REPO:latest" "$REPO:9418571@$D1")" '{}' \
  "[warn] im image pin — not pinned by digest: ${REPO}:latest"

# Healthy: pinned, and the node runs exactly that digest.
run healthy       "$PINNED" "$(pods_json "$REPO@$D1" "$REPO@$D1")" \
  "[ok] im image pin (running == ${D1:0:19}"

# ── #66's shape: spec pinned, node runs something else, all else green ──────
run running-differs "$PINNED" "$(pods_json "$REPO@$D2")" \
  "[warn] im image pin — running ${D2} "

# Pinned but nothing running to compare: said, not silent.
run no-pods       "$PINNED" '{"items":[]}' \
  "[warn] im image pin — pinned, but no running container to compare"

echo

if [[ "${SEEN[running-differs]}" == "ok" ]]; then
  echo "FAIL  a node running a digest that is not the pinned one reported ok —"
  echo "      that is #66 exactly, with the pin present and useless."
  FAILED=$((FAILED + 1))
fi
if [[ "${SEEN[healthy]}" != "ok" ]]; then
  echo "FAIL  a healthy pinned deployment did not report ok — a row that warns"
  echo "      at every input carries no information."
  FAILED=$((FAILED + 1))
fi

if [[ "${SEEN[absent]}" == "ok" || "${SEEN[pre-handover]}" == "ok" ]]; then
  echo "FAIL  a branch that measured nothing reported ok — could-not-measure"
  echo "      folded into pass is the exact conflation this row exists to avoid."
  FAILED=$((FAILED + 1))
fi

DISTINCT=$(printf '%s\n' "${SEEN[@]}" | sort -u | wc -l | tr -d ' ')
if (( DISTINCT < 3 )); then
  echo "FAIL  only ${DISTINCT} distinct level(s) across ${#SEEN[@]} cases —"
  echo "      ok, warn and skip should all appear."
  FAILED=$((FAILED + 1))
fi

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — ${#SEEN[@]} cases match, ${DISTINCT} distinct levels, running≠pinned ≠ ok, unmeasured ≠ ok"
