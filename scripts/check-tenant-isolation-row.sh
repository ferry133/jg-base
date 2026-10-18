#!/usr/bin/env bash
# Assert daily-check row 28 (tenant isolation, sub-change
# tenant-isolation-baseline §4; fleet-ops root `standalone-app-repos` 2.3)
# gives every verdict it claims, from the real block in the ConfigMap.
#
# The kubectl stub answers ONLY the four reads the row makes (namespaces with
# -l jg.tenant, clusterrolebindings, rolebindings -A, pvc -A), from per-case
# fixtures, and fails loudly on anything else: a stub that ignores its
# arguments is a constant, and a row reading the wrong object would pass.
#
# Usage: scripts/check-tenant-isolation-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cannot measure: jq is missing"; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant-row.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

BLOCK="$(awk '
    /^[[:space:]]*# 28\. Tenant isolation invariants/ { grabbing = 1 }
    grabbing && /^[[:space:]]*# [0-9]+[a-z]?\. / && !/# 28\./ { exit }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: row 28 was not found in the ConfigMap"; exit 2; }
grep -q 'kubectl get clusterrolebindings -o json' <<<"$BLOCK" || { echo "cannot measure: extracted block is not row 28"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

# The RBAC the row needs must be granted to the Job.
RBAC="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/rbac.yaml"
rc=0
fail() { echo "FAIL — $1"; rc=1; }
grep -qE 'resources: \["clusterrolebindings", "rolebindings"\]' "$RBAC" \
  || fail "rbac.yaml does not grant list on clusterrolebindings and rolebindings — the row would always skip"

ns() {  # name level granted(yes|no)
  local lbl="\"jg.tenant\": \"$1\""
  [[ -n "$2" ]] && lbl="$lbl, \"pod-security.kubernetes.io/enforce\": \"$2\""
  [[ "$3" == yes ]] && lbl="$lbl, \"jg.tenant-privileged\": \"granted\""
  printf '{"metadata":{"name":"%s","labels":{%s}}}' "$1" "$lbl"
}
rb() {  # ns name roleKind roleName subjectSA
  printf '{"metadata":{"namespace":"%s","name":"%s"},"roleRef":{"kind":"%s","name":"%s"},"subjects":[{"kind":"ServiceAccount","namespace":"flux-system","name":"%s"}]}' "$@"
}
OK_RB="$(rb acme tenant-acme ClusterRole tenant-admin tenant-acme)"

# case name | namespaces items | crb items | rb items | pvc items | refuse (list of reads to fail) | want level | want text
run_case() {
  local name="$1" nsi="$2" crb="$3" rbi="$4" pvc="$5" refuse="$6" want="$7" text="$8"
  printf '{"items":[%s]}' "$nsi" > "$WORK/ns.json"
  printf '{"items":[%s]}' "$crb" > "$WORK/crb.json"
  printf '{"items":[%s]}' "$rbi" > "$WORK/rb.json"
  printf '{"items":[%s]}' "$pvc" > "$WORK/pvc.json"
  out="$(REFUSE="$refuse" W="$WORK" bash -c '
    set -uo pipefail
    record() { echo "$1|$2|${3:-}"; }
    kubectl() {
      case "$*" in
        "get namespaces -l jg.tenant -o json") [[ " $REFUSE " == *" ns "* ]] && return 1; cat "$W/ns.json" ;;
        "get clusterrolebindings -o json") [[ " $REFUSE " == *" crb "* ]] && return 1; cat "$W/crb.json" ;;
        "get rolebindings -A -o json") [[ " $REFUSE " == *" rb "* ]] && return 1; cat "$W/rb.json" ;;
        "get persistentvolumeclaims -A -o json") [[ " $REFUSE " == *" pvc "* ]] && return 1; cat "$W/pvc.json" ;;
        *) echo "STUB: unexpected kubectl $*" >&2; return 99 ;;
      esac
    }
    '"$BLOCK"'
  ' 2>&1)"
  if grep -q '^STUB:' <<<"$out"; then fail "$name: the row asked kubectl something unexpected: $(grep '^STUB:' <<<"$out" | head -1)"; return; fi
  local lines; lines="$(grep -c '|Tenant isolation|' <<<"$out")"
  if [[ "$lines" -ne 1 ]]; then fail "$name: expected exactly one record, got $lines: $out"; return; fi
  local got; got="$(grep '|Tenant isolation|' <<<"$out")"
  if [[ "${got%%|*}" == "$want" ]] && grep -qF -- "$text" <<<"$got"; then
    echo "PASS  $name  ->  ${got%%|*}: ${got##*|}"
  else
    fail "$name: wanted $want with \"$text\", got: $got"
  fi
}

run_case "0 no tenants" "" "" "" "" "" skip "no tenants declared"
run_case "1 namespaces unreadable" "" "" "" "" "ns" skip "namespaces could not be listed"
run_case "2 RBAC unreadable" "$(ns acme restricted no)" "" "$OK_RB" "" "rb" skip "no RBAC read permission"
run_case "3 PVCs unreadable" "$(ns acme restricted no)" "" "$OK_RB" "" "pvc" skip "persistentvolumeclaims could not be listed"
run_case "4 compliant tenant" "$(ns acme restricted no)" "" "$OK_RB" "" "" ok "1 tenant namespace(s): acme"
run_case "5 compliant + PVC" "$(ns acme restricted no)" "" "$OK_RB" '{"metadata":{"namespace":"acme","name":"data"}}' "" warn "acme/data"
run_case "6 PVC outside tenants ignored" "$(ns acme restricted no)" "" "$OK_RB" '{"metadata":{"namespace":"claudecode","name":"x"}}' "" ok "bindings only to tenant-admin"
run_case "7 binding to admin" "$(ns acme restricted no)" "" "$OK_RB,$(rb acme oops ClusterRole admin someone)" "" "" fail "binds ClusterRole admin in a tenant namespace"
run_case "8 tenant SA bound to edit" "$(ns acme restricted no)" "" "$(rb acme tenant-acme ClusterRole edit tenant-acme)" "" "" fail "not tenant-admin"
run_case "9 CRB names a tenant SA" "$(ns acme restricted no)" '{"metadata":{"name":"leak"},"roleRef":{"kind":"ClusterRole","name":"view"},"subjects":[{"kind":"ServiceAccount","namespace":"flux-system","name":"tenant-acme"}]}' "$OK_RB" "" "" fail "ClusterRoleBinding leak names a tenant ServiceAccount"
run_case "10 privileged by grant" "$(ns edge privileged yes)" "" "$(rb edge tenant-edge ClusterRole tenant-admin tenant-edge)" "" "" ok "privileged by grant: edge"
run_case "11 privileged without grant" "$(ns edge privileged no)" "" "$(rb edge tenant-edge ClusterRole tenant-admin tenant-edge)" "" "" fail "privileged without jg.tenant-privileged=granted"
run_case "12 no PSA label" "$(ns acme "" no)" "" "$OK_RB" "" "" fail "has no pod-security enforce label"
run_case "13 admin in a NON-tenant namespace ignored" "$(ns acme restricted no)" "" "$OK_RB,$(rb default ops ClusterRole admin someone)" "" "" ok "1 tenant namespace(s)"
run_case "14 two tenants, prefix names" "$(ns acme restricted no),$(ns acme-db restricted no)" "" "$OK_RB,$(rb acme-db tenant-acme ClusterRole tenant-admin tenant-acme)" '{"metadata":{"namespace":"acm","name":"x"}}' "" ok "2 tenant namespace(s): acme acme-db"

[[ $rc -eq 0 ]] && echo "ok — row 28 gives skip/ok/warn/fail as specified across 15 cases, and its RBAC is granted"
exit $rc
