#!/usr/bin/env bash
# Assert what daily-check's IM IMAGE PIN row (check 23) emits, per cluster
# state — including whether it can tell those states apart at all.
#
# ferry133/jg-base#66: `latest` on a spegel cluster froze silently — the pod
# restarted, kubelet said Pulled, the Deployment said Running, and it was a
# months-old image. The pin (#67) removes the freeze; check 23 guards the two
# ways the pin can rot (spec back on a mutable tag; running digest != pinned).
# The case that must not regress is `running-differs`: that is #66's shape,
# and every other signal on the report reads green through it.
#
# ── Why this file was rewritten (ferry133/jg-base#108, 2026-09-14) ──────────
#
# From 2026-09-06 to 2026-09-14 check 23 measured NOTHING on any cluster, and
# this file passed on every one of those days.
#
# The row gated on the Deployment's `helm.toolkit.fluxcd.io/name` — which
# carries the HELMRELEASE name, always `im` — compared against
# `claude-code-im`, a KUSTOMIZATION name (`im-ks.yaml`) that no HelmRelease
# has ever had. The comparison could not come out false, so every branch
# below it was unreachable.
#
# This file did not catch it because its own fixture supplied
# `"helm.toolkit.fluxcd.io/name":"claude-code-im"` — **a label value no
# cluster can produce**. The fixture invented the state the code needed in
# order to work, and then confirmed the code worked in it. Worse, its
# `pre-handover` case used the label value `im`, which is what MIGRATED
# clusters actually carry: the test had the two states exactly backwards and
# still reported four distinct levels and a passing run.
#
# So the fixtures here are now built from what was measured on live clusters
# (FO-openspec [8e8ef1], all three, 2026-09-14, jg-base main@356954c):
#
#   deploy/im       helm.toolkit.fluxcd.io/name=im, /namespace=claudecode
#                   and NO kustomize.toolkit.fluxcd.io/* label at all
#   helmrelease/im  kustomize.toolkit.fluxcd.io/name=claude-code-im
#
# with a positive control that shares the property — claudecode's
# deploy/postgres DOES carry kustomize.toolkit.fluxcd.io/name=claudecode-db,
# because kustomize-controller applies that Deployment directly. The label
# follows who applied the object, not who owns the chain.
#
# Stated plainly, because it is the one thing here that is not a reading:
# there is no pre-handover `im` anywhere on the fleet to measure — all three
# clusters have `claude-code-im` un-suspended and `claude-code-instances`
# holding zero objects. The `claude-code-instances` case below is CONSTRUCTED
# from the mechanism above. It is a fixture, not a reading, and this comment
# is the only thing that says so.
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
    echo "cannot measure: $tool required. CI installs yq pinned in the"
    echo "'scripts' job of .github/workflows/flux-local.yaml; jq ships on the"
    echo "runner image."
    # 2, not 1: a missing tool and a caught regression must not be the same
    # colour. FO-openspec [8e8ef1] ran four mutations against this file and got
    # rc=1 from all four — every one of them "yq required", none of them a
    # finding. Only the log told them apart. (#108 follow-up, 2026-09-14.)
    exit 2
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
    # Check 24 follows 23 (fleet-ops#11). Ending at "Compiling report" would
    # source 24 too, and its record() would overwrite this row's result.
    end = s.index("# 24. Omni service-account key expiry")
except ValueError:
    sys.exit("could not locate the im-pin block in run-check.sh — markers moved")
blk = s[start:end]
if "imageID" not in blk:
    sys.exit("located a block that never reads imageID — the running half of #66's guard is gone")
if "@sha256:" not in blk:
    sys.exit("located a block that never tests for @sha256: — the pin half is gone")
if "get helmrelease" not in blk:
    sys.exit("located a block that never asks the HelmRelease who applied it — #108's two-hop "
             "resolution is gone, and the Deployment alone cannot answer it")
if "kustomize\\.toolkit\\.fluxcd\\.io/name}" not in blk:
    sys.exit("the HelmRelease is read, but not for its kustomize.toolkit.fluxcd.io/NAME — any "
             "other key on that object answers the same for every cluster, so the gate would be "
             "blind again in a new way (#108 follow-up)")
(work / "block.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

D1="sha256:$(printf 'a%.0s' $(seq 64))"
D2="sha256:$(printf 'b%.0s' $(seq 64))"
REPO="ghcr.io/ferry133/claude-code"

# $1 = "labeled" (what every real im Deployment carries) | "unlabeled"
# $2.. = container images
deploy_json() {
  local kind="$1"; shift
  local labels='"helm.toolkit.fluxcd.io/name":"im","helm.toolkit.fluxcd.io/namespace":"claudecode"'
  [[ "$kind" == "unlabeled" ]] && labels='"app.kubernetes.io/name":"im"'
  local imgs="" i
  for i in "$@"; do imgs="${imgs}{\"name\":\"c\",\"image\":\"$i\"},"; done
  printf '{"metadata":{"labels":{%s}},"spec":{"selector":{"matchLabels":{"app":"im"}},"template":{"spec":{"containers":[%s],"initContainers":[]}}}}' \
    "$labels" "${imgs%,}"
}
pods_json() {
  local ids="" i
  for i in "$@"; do ids="${ids}{\"imageID\":\"$i\"},"; done
  printf '{"items":[{"status":{"containerStatuses":[%s],"initContainerStatuses":[]}}]}' "${ids%,}"
}

FAILED=0
declare -A SEEN=()
declare -A MSG=()

# $1=label $2=deploy json or ABSENT  $3=pods json
# $4=HR state: a Kustomization name, "" (HR exists, unlabeled), or UNREADABLE
# $5=expected prefix   [$6=block override, for the positive control]
run() {
  local label="$1" deploy="$2" pods="$3" hr="$4" want="$5" blk="${6:-$WORK/block.sh}"
  # Every case starts from nothing. These are sourced into THIS shell, so a
  # variable one case sets is still set in the next — and a case that reads a
  # neighbour's leftover passes for the wrong reason. (Seen while writing
  # this: the #108 control printed the previous case's IM_KS.)
  unset IM_JSON IM_HR IM_HR_NS IM_KS IM_OWNER IM_UNPINNED IM_PINS IM_SEL IM_RUN
  OUT=""
  record() { OUT="[$1] $2${3:+ — $3}"; }
  kubectl() {
    case "$*" in
      *"get deploy im"*)   [[ "$deploy" == "ABSENT" ]] && return 1; printf '%s' "$deploy" ;;
      *"get helmrelease"*)
        [[ "$hr" == "UNREADABLE" ]] && return 1
        # Resolve the jsonpath the caller actually asked for, instead of
        # handing back the fixture regardless. A stub that ignores its
        # arguments does not model the remote half, and the test then passes
        # on a block that reads the WRONG KEY. Measured by FO-openspec
        # [8e8ef1] on this very file: swapping the block's jsonpath to
        # `…/namespace}` left this suite at exit 0, while three live clusters
        # would print `im applied by Kustomization 'flux-system'` every day —
        # a new blind gate the same colour as the old one (#108).
        case "$*" in
          *'kustomize\.toolkit\.fluxcd\.io/name}'*)      printf '%s' "$hr" ;;
          *'kustomize\.toolkit\.fluxcd\.io/namespace}'*) printf '%s' "flux-system" ;;
          *) echo "UNEXPECTED helmrelease jsonpath: $*" >&2; return 1 ;;
        esac ;;
      *"get pods"*)        printf '%s' "$pods" ;;
      *) echo "UNEXPECTED kubectl: $*" >&2; return 1 ;;
    esac
  }
  # shellcheck disable=SC1091
  source "$blk"
  unset -f kubectl record 2>/dev/null || true

  local got="${OUT:-<no row>}"
  local level="${got%%]*}"; level="${level#[}"
  SEEN["$label"]="$level"; MSG["$label"]="$got"
  if [[ "$got" == "$want"* ]]; then
    printf 'PASS  %-18s -> %s\n' "$label" "${got:0:88}"
  else
    printf 'FAIL  %-18s -> %s\n        expected %s...\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

PINNED="$(deploy_json labeled "$REPO:9418571@$D1" "$REPO:9418571@$D1" "$REPO:9418571@$D1")"

# ── the three ways of measuring nothing. Each says something DIFFERENT, on
#    purpose: #108 survived eight days as one skip reason standing in for
#    several unrelated states, and its wording read as correct.
run absent        ABSENT  "$(pods_json "$REPO@$D1")" claude-code-im \
  "[skip] im image pin — no im deployment"
run no-helm-label "$(deploy_json unlabeled "$REPO:9418571@$D1")" "$(pods_json "$REPO@$D1")" claude-code-im \
  "[skip] im image pin — deploy/im has no helm.toolkit.fluxcd.io"
run hr-unreadable "$PINNED" "$(pods_json "$REPO@$D1")" UNREADABLE \
  "[skip] im image pin — helmrelease claudecode/im could not be read"

# Pre-handover: the Deployment label is `im`, exactly as on a migrated
# cluster. Only the HelmRelease's applier tells them apart. CONSTRUCTED, see
# the header — there is no live instance of this state to read.
run pre-handover  "$PINNED" "$(pods_json "$REPO@$D1")" claude-code-instances \
  "[skip] im image pin — im applied by Kustomization 'claude-code-instances'"

# ── the branches #108 made unreachable ─────────────────────────────────────
run unpinned      "$(deploy_json labeled "$REPO:latest" "$REPO:9418571@$D1")" '{}' claude-code-im \
  "[warn] im image pin — not pinned by digest: ${REPO}:latest"
run healthy       "$PINNED" "$(pods_json "$REPO@$D1" "$REPO@$D1")" claude-code-im \
  "[ok] im image pin (running == ${D1:0:19}"
run running-differs "$PINNED" "$(pods_json "$REPO@$D2")" claude-code-im \
  "[warn] im image pin — running ${D2} "
run no-pods       "$PINNED" '{"items":[]}' claude-code-im \
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
if [[ "${SEEN[absent]}" == "ok" || "${SEEN[pre-handover]}" == "ok" \
   || "${SEEN[hr-unreadable]}" == "ok" || "${SEEN[no-helm-label]}" == "ok" ]]; then
  echo "FAIL  a branch that measured nothing reported ok — could-not-measure"
  echo "      folded into pass is the exact conflation this row exists to avoid."
  FAILED=$((FAILED + 1))
fi

# #108 itself: four states must not collapse into one sentence. Distinct
# LEVELS are not enough — the old row emitted skip/warn/ok across its cases
# too, because its fixture fed it a value no cluster produces.
DISTINCT_SKIPS=$(printf '%s\n' "${MSG[absent]}" "${MSG[no-helm-label]}" \
  "${MSG[hr-unreadable]}" "${MSG[pre-handover]}" | sort -u | wc -l | tr -d ' ')
if (( DISTINCT_SKIPS < 4 )); then
  echo "FAIL  only ${DISTINCT_SKIPS} distinct not-measured message(s) across 4 states —"
  echo "      a reader cannot tell which one their cluster hit, which is how"
  echo "      #108 read as correct for eight days."
  FAILED=$((FAILED + 1))
fi

DISTINCT=$(printf '%s\n' "${SEEN[@]}" | sort -u | wc -l | tr -d ' ')
if (( DISTINCT < 3 )); then
  echo "FAIL  only ${DISTINCT} distinct level(s) across ${#SEEN[@]} cases —"
  echo "      ok, warn and skip should all appear."
  FAILED=$((FAILED + 1))
fi

# ── positive control: this suite must REJECT the #108 gate ─────────────────
# Re-created from the live block, anchored on the two lines that bound the
# gate. Without this, "the suite passes" and "the suite cannot fail" are the
# same output — and that is precisely what the previous version of this file
# was.
awk '
  /^  IM_HR=/ && !replaced {
    print "  IM_OWNER=$(echo \"$IM_JSON\" | jq -r '"'"'.metadata.labels[\"helm.toolkit.fluxcd.io/name\"] // \"\"'"'"')"
    print "  if [[ \"$IM_OWNER\" != \"claude-code-im\" ]]; then"
    dropping = 1; replaced = 1; next
  }
  dropping && /^  elif \[\[ "\$IM_KS" /                                 { dropping = 0; next }
  !dropping { print }
' "$WORK/block.sh" > "$WORK/block-108.sh"
if ! bash -n "$WORK/block-108.sh" 2>/dev/null; then
  echo "FAIL  the re-created #108 gate does not parse — the control is vacuous,"
  echo "      so nothing above is evidence. (A control whose reconstruction"
  echo "      breaks dies the same colour as one that caught something.)"
  FAILED=$((FAILED + 1))
elif ! grep -q 'IM_OWNER' "$WORK/block-108.sh" || grep -q 'IM_KS=' "$WORK/block-108.sh"; then
  echo "FAIL  could not re-create the #108 gate from the live block — the fix"
  echo "      moved, so this control is vacuous and the run above proves nothing."
  FAILED=$((FAILED + 1))
else
  # Not via run(): that records into SEEN/FAILED, and here a NON-match is
  # the pass. Captured directly instead.
  CTRL_OUT=""
  ctrl_probe() {
    # Every case starts from nothing. These are sourced into THIS shell, so a
    # variable one case sets is still set in the next — and a case that reads a
    # neighbour's leftover passes for the wrong reason. (Seen while writing
    # this: the #108 control printed the previous case's IM_KS.)
    unset IM_JSON IM_HR IM_HR_NS IM_KS IM_OWNER IM_UNPINNED IM_PINS IM_SEL IM_RUN
    OUT=""
    record() { OUT="[$1] $2${3:+ — $3}"; }
    kubectl() {
      case "$*" in
        *"get deploy im"*)   printf '%s' "$PINNED" ;;
        *'kustomize\.toolkit\.fluxcd\.io/name}'*)      printf '%s' "claude-code-im" ;;
        *'kustomize\.toolkit\.fluxcd\.io/namespace}'*) printf '%s' "flux-system" ;;
        *"get helmrelease"*) return 1 ;;
        *"get pods"*)        pods_json "$REPO@$D1" ;;
        *) return 1 ;;
      esac
    }
    # shellcheck disable=SC1091
    source "$WORK/block-108.sh"
    unset -f kubectl record 2>/dev/null || true
    CTRL_OUT="${OUT:-<no row>}"
  }
  ctrl_probe
  if [[ "$CTRL_OUT" == "[ok]"* ]]; then
    echo "FAIL  positive control: the #108 gate reached the pin comparison in"
    echo "      this harness and reported ok. It cannot on a real cluster, so"
    echo "      these fixtures are still supplying a label value that does not"
    echo "      occur — which is exactly how this file passed for eight days."
    FAILED=$((FAILED + 1))
  else
    printf 'PASS  %-18s -> rejected: %s\n' "ctrl-108" "${CTRL_OUT:0:72}"
  fi
fi

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — 8 cases match, ${DISTINCT} distinct levels, 4 distinct not-measured reasons,"
echo "     running≠pinned ≠ ok, unmeasured ≠ ok, and the #108 gate is rejected"
