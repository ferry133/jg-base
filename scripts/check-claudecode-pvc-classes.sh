#!/usr/bin/env bash
# Assert the base `im` claims do not share a storage class variable, and that
# both still retain.
#
# ferry133/jg-base#136 (from jg-cluster-template#191, hit on a bench while
# enabling Longhorn): `claude-workspace` read ${DEFAULT_STORAGE_CLASS}, the
# bulk tier's name. Move that tier and the claim's storageClassName moves with
# it -- and a bound PVC's spec is immutable, so the HelmRelease wedges
# permanently: `PersistentVolumeClaim "im-claude-workspace" is invalid: spec:
# Forbidden: spec is immutable after creation`. Helm rolled back, so nothing
# stopped serving; the only symptom was that this HelmRelease never reconciled
# again. On a third cluster the failure was already being worked around by
# pinning the bulk default back to local-path.
#
# ⚠️ `retain: true` is asserted too, and it is not decoration: it is what makes
# this a BLOCKED UPGRADE rather than DATA LOSS. Drop it and the same storage
# move deletes the workspace instead of wedging -- a strictly worse failure
# that this guard's own subject would otherwise stop describing.
#
# ⚠️ Not asserted: which classes the clusters actually use. That is per-cluster
# (measured 2026-09-23: jg-jiahd sc-nas, jcom sc-nas, jg-jcc1 local-path) and
# lives in each cluster's secrets, not here.
#
# Usage: scripts/check-claudecode-pvc-classes.sh
#   exit 0 the claims are independent and retained, 1 not, 2 cannot measure
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HR="$ROOT/kubernetes/apps/base/claudecode/claude-code/im/enabled/helmrelease.yaml"
[[ -r "$HR" ]] || { echo "cannot measure: $HR not readable"; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }

BASE='select(.kind == "HelmRelease") | .spec.values.persistence'
# ⚠️ No `// ""` fallback. In yq/jq the alternative operator fires on ANY falsy
# value, and `false` is falsy -- so `retain: false` read back as the empty
# string and this guard reported it as "<unset>". Correct verdict, wrong
# reason, and the reason is what sends the next reader to a line. Map an
# absent key explicitly instead.
get() { yq -r "${BASE}.$1" "$HR"; }   # prints `null` when absent, `false` when false

CFG_CLASS="$(get 'claude-config.storageClass')"
WS_CLASS="$(get 'claude-workspace.storageClass')"
CFG_KEEP="$(get 'claude-config.retain')"
WS_KEEP="$(get 'claude-workspace.retain')"
WS_SIZE="$(get 'claude-workspace.size')"

# Instrument control: a field known to be present must read back, or an empty
# storageClass below says nothing about the manifest.
[[ -n "$WS_SIZE" && "$WS_SIZE" != "null" ]] \
  || { echo "cannot measure: the reader could not see claude-workspace.size either, so the values above are not readings"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

for pair in "claude-config:$CFG_CLASS" "claude-workspace:$WS_CLASS"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [[ -n "$val" && "$val" != "null" ]] || { fail "${name} has no storageClass — it would take the cluster default, which is the bulk tier by another route"; continue; }
  case "$val" in
    '${'*'}') : ;;
    *) fail "${name}.storageClass is the literal '${val}' — hard-coding it makes every cluster identical, which is the opposite of what these two variables are for" ;;
  esac
  case "$val" in
    *DEFAULT_STORAGE_CLASS*)
      fail "${name}.storageClass is back on the bulk tier ('${val}') — moving that tier then changes a BOUND claim's storageClassName, and a PVC's spec is immutable, so the HelmRelease wedges for good (#136)" ;;
  esac
done

# The two must not be the same name either: sharing a name is the same coupling
# with a different label on it.
[[ "$CFG_CLASS" != "$WS_CLASS" ]] \
  || fail "both claims read the same variable ('${CFG_CLASS}') — whatever moves one moves the other, which is the coupling #136 removed wearing a different name"

for pair in "claude-config:$CFG_KEEP" "claude-workspace:$WS_KEEP"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [[ "$val" == "true" ]] \
    || fail "${name}.retain is '${val}', not true — retain is what makes a storage move a blocked upgrade instead of a deleted volume"
done

if [[ $rc -eq 0 ]]; then
  echo "PASS — claude-config uses ${CFG_CLASS}, claude-workspace uses ${WS_CLASS};"
  echo "       different names, neither on the bulk tier, both retain: true"
  echo "       (reader control: claude-workspace.size read back as ${WS_SIZE})"
fi
exit $rc
