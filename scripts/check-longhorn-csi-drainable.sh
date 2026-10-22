#!/usr/bin/env bash
# Assert Longhorn's csi-attacher and csi-provisioner run at least 2 replicas.
#
# ferry133/jg-base#208: longhorn-manager creates a PodDisruptionBudget with
# minAvailable 1 for these two Deployments whenever a volume is attached
# (v1.12.0 controller/kubernetes_pdb_controller.go; not configurable). At 1
# replica that PDB allows 0 disruptions, and Omni v1.12.4 drains before every
# Talos upgrade and respects PDBs -- so the node holding the pod never drains.
# Measured on jg-jiahd: talos-dk0-t6p cordoned ~22.8h, 2026-10-21.
#
# An absent key passes: the chart then omits the env var and longhorn-manager
# uses its own default, 3 (csi/deployment.go). 0 and 1 fail.
# Not asserted: resizer and snapshotter. Longhorn makes no PDB for them.
#
# Usage: scripts/check-longhorn-csi-drainable.sh [--self-test]
#   exit 0 drainable, 1 not, 2 cannot measure
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HR="$ROOT/kubernetes/apps/base/storage/longhorn/app/helmrelease.yaml"
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }

check() {  # FILE -> verdict lines; 0/1/2
  local f="$1" bad=0 k v
  [[ -r "$f" ]] || { echo "cannot measure: $f not readable"; return 2; }
  [[ "$(yq -r 'select(.kind == "HelmRelease") | .metadata.name' "$f")" == longhorn ]] \
    || { echo "cannot measure: no HelmRelease named longhorn in $f"; return 2; }
  for k in attacherReplicaCount provisionerReplicaCount; do
    v="$(yq -r "select(.kind == \"HelmRelease\") | .spec.values.csi.$k" "$f")"
    if [[ "$v" == null ]]; then
      echo "ok — csi.$k unset (longhorn-manager default 3)"
    elif [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 2 )); then
      echo "ok — csi.$k = $v"
    else
      echo "FAIL — csi.$k = $v: Longhorn's PDB (minAvailable 1) then allows 0 disruptions and that node cannot drain (#208)"; bad=1
    fi
  done
  return $bad
}

if [[ "${1:-}" != "--self-test" ]]; then check "$HR"; exit $?; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/lh-csi.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$W"' EXIT
cp "$HR" "$W/hr.yaml" || { echo "cannot measure: cannot copy $HR"; exit 2; }
rc=0
expect() {  # NAME WANT_RC WANT_TEXT YQ_EXPR
  cp "$HR" "$W/hr.yaml"
  [[ -z "$4" ]] || yq -i "$4" "$W/hr.yaml" || { echo "CANNOT MEASURE  $1: mutation failed"; exit 2; }
  [[ -z "$4" ]] || ! cmp -s "$HR" "$W/hr.yaml" || { echo "CANNOT MEASURE  $1: mutation did not change the file"; exit 2; }
  local out mrc; out="$(check "$W/hr.yaml")"; mrc=$?
  if [[ $mrc -eq $2 ]] && grep -qF -- "$3" <<<"$out"; then echo "PASS  $1  ->  $(grep -F -- "$3" <<<"$out" | head -1)"
  else echo "FAIL  $1: rc=$mrc wanted $2 and \"$3\": $out"; rc=1; fi
}
expect "0 as committed" 0 "ok — csi.provisionerReplicaCount" ""
expect "1 attacher back to 1 (the #208 state)" 1 "FAIL — csi.attacherReplicaCount = 1" 'select(.kind == "HelmRelease").spec.values.csi.attacherReplicaCount = 1'
expect "2 provisioner back to 1" 1 "FAIL — csi.provisionerReplicaCount = 1" 'select(.kind == "HelmRelease").spec.values.csi.provisionerReplicaCount = 1'
expect "3 zero" 1 "FAIL — csi.attacherReplicaCount = 0" 'select(.kind == "HelmRelease").spec.values.csi.attacherReplicaCount = 0'
expect "4 key removed (upstream default 3)" 0 "csi.attacherReplicaCount unset" 'del(select(.kind == "HelmRelease").spec.values.csi.attacherReplicaCount)'
expect "5 resizer at 1 is not this guard's business" 0 "ok — csi.attacherReplicaCount = 2" 'select(.kind == "HelmRelease").spec.values.csi.resizerReplicaCount = 1 | select(.kind == "HelmRelease").spec.values.csi.snapshotterReplicaCount = 0'
[[ $rc -eq 0 ]] && echo "ok — self-test: committed passes, three under-2 values fail, absent and resizer/snapshotter pass"
exit $rc
