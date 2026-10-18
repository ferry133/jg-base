#!/usr/bin/env bash
# Assert ClusterRole tenant-admin never grants what would let a tenant leave
# its namespaces (ferry133/jg-base#190; fleet-ops root `standalone-app-repos`
# D3; sub-change tenant-isolation-baseline §2, decision D-a).
#
# The role is an allow list; THIS pins the deny list, because the failure that
# matters is a line added later — by a vendor asking for "just one more
# resource" — that turns the boundary into decoration. Three classes, all
# required by D-a:
#   1. API groups / resources: any *.toolkit.fluxcd.io (a Kustomization or
#      HelmRelease without serviceAccountName is applied as cluster-admin),
#      cilium.io and NetworkPolicy (Cilium ORs allow rules: a tenant policy
#      widens the platform's), storage.k8s.io, and every cluster-scoped kind.
#   2. verbs escalate / bind / impersonate: with them, a tenant writes itself
#      a Role granting the Flux API and the class-1 check never sees it.
#   3. `*` in apiGroups, resources or verbs, and nonResourceURLs.
# Plus one this role's own comments promise: ResourceQuota and LimitRange are
# read-only, or a tenant raises its own quota and its LAN-IP grant with it.
#
# Usage: scripts/check-tenant-admin-role.sh [--self-test] [FILE]
#   --self-test  the unmutated role must pass, and each mutation (one per
#                class, the three #190 names first) must fail for its reason
#   exit 0 pass, 1 fail, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="$ROOT/kubernetes/apps/base/flux-system/tenant-rbac/clusterrole.yaml"
for t in yq jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }
done

# Cluster-scoped kinds a namespaced role could still name. A ClusterRole bound
# by a RoleBinding cannot reach them, but listing one means somebody expected
# it to — and the same rule bound by a ClusterRoleBinding would.
CLUSTER_SCOPED='
core:nodes core:persistentvolumes core:namespaces core:componentstatuses
rbac.authorization.k8s.io:clusterroles rbac.authorization.k8s.io:clusterrolebindings
networking.k8s.io:ingressclasses networking.k8s.io:ipaddresses networking.k8s.io:servicecidrs
gateway.networking.k8s.io:gatewayclasses
'
# Groups whose every kind is cluster-scoped or platform-owned.
FORBIDDEN_GROUP_RE='(^|\.)toolkit\.fluxcd\.io$|^cilium\.io$|^storage\.k8s\.io$|^apiextensions\.k8s\.io$|^admissionregistration\.k8s\.io$|^apiregistration\.k8s\.io$|^certificates\.k8s\.io$|^scheduling\.k8s\.io$|^node\.k8s\.io$|^flowcontrol\.apiserver\.k8s\.io$|^authentication\.k8s\.io$|^authorization\.k8s\.io$'
WRITE_VERBS='create update patch delete deletecollection'

# check FILE -> prints one FAIL line per finding; exit 0 / 1 / 2
check() {
  local file="$1" json
  [[ -r "$file" ]] || { echo "cannot measure: $file not readable"; return 2; }
  json="$(yq -o=json -I=0 'select(.kind == "ClusterRole" and .metadata.name == "tenant-admin")' "$file" 2>/dev/null)"
  [[ -n "$json" ]] || { echo "cannot measure: no ClusterRole tenant-admin in $file"; return 2; }
  [[ "$(wc -l <<<"$json")" -eq 1 ]] || { echo "FAIL — more than one ClusterRole tenant-admin in $file"; return 1; }
  # Positive control: the reader sees the role's content, not an empty shell.
  jq -e '[.rules[]? | select((.apiGroups // []) | index("")) | .resources[]?] | index("pods")' \
    <<<"$json" >/dev/null || { echo "cannot measure: read tenant-admin but found no core pods rule — wrong file or wrong reader"; return 2; }

  local bad=0 g r v saw_core=0
  say() { echo "FAIL — $1"; bad=1; }
  # One line per (group, resource, verb). The core group is "" and is printed
  # as `core`: with a whitespace IFS such as a tab, `read` drops a leading
  # empty field and every core rule shifts one column left — the first
  # version of this file passed the real role that way, reading resources as
  # groups and verbs as resources (its own self-test caught it).
  while IFS=$'\x1f' read -r g r v; do
    [[ "$g" == "core" ]] && saw_core=1
    [[ "$g" == "*" ]] && say "apiGroups contains \"*\""
    [[ "$r" == "*" || "$r" == "*/"* ]] && say "resources contains \"$r\" (group \"$g\")"
    [[ "$v" == "*" ]] && say "verbs contains \"*\" (group \"$g\", resource $r)"
    case "$v" in escalate|bind|impersonate) say "verb $v (group \"$g\", resource $r)";; esac
    if [[ "$g" =~ $FORBIDDEN_GROUP_RE ]]; then say "forbidden API group \"$g\" (resource $r)"; fi
    for cs in $CLUSTER_SCOPED; do
      [[ "$g:${r%%/*}" == "$cs" ]] && say "cluster-scoped kind $r (group \"$g\")"
    done
    [[ "$g" == "networking.k8s.io" && "${r%%/*}" == "networkpolicies" ]] && \
      say "networkpolicies — a tenant policy would widen the platform's tenant-ingress"
    if [[ "$g" == "core" ]] && [[ "${r%%/*}" == "resourcequotas" || "${r%%/*}" == "limitranges" ]]; then
      for w in $WRITE_VERBS; do [[ "$v" == "$w" ]] && say "write verb $v on $r — a tenant would raise its own quota"; done
    fi
  done < <(jq -r '.rules[] | (.apiGroups // [""])[] as $g | (.resources // ["(none)"])[] as $r | (.verbs // [])[] as $v | [(if $g == "" then "core" else $g end), $r, $v] | join("\u001f")' <<<"$json" | sort -u)
  jq -e '[.rules[] | select(.nonResourceURLs)] | length == 0' <<<"$json" >/dev/null || say "nonResourceURLs present"
  # Red wins over "cannot measure": a finding made before the reader turned
  # out to be unreliable is still a finding.
  [[ $bad -eq 1 ]] && return 1
  # The same control again, on what the LOOP saw rather than what jq found:
  # the shifted-column defect above passed jq's control and fails this one.
  # Anchored on the group, not on any verb or resource a mutation might be
  # rewriting.
  [[ $saw_core -eq 1 ]] || { echo "cannot measure: the rule reader saw no core-group rule — it is misreading the rules"; return 2; }
  return 0
}

if [[ "${1:-}" != "--self-test" ]]; then
  out="$(check "${1:-$ROLE}")"; rc=$?
  [[ -n "$out" ]] && sort -u <<<"$out"
  [[ $rc -eq 0 ]] && echo "ok — tenant-admin grants no Flux/cilium/storage/cluster-scoped kind, no escalate/bind/impersonate, no wildcard, quota read-only"
  exit $rc
fi

# --- self-test ---------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant-admin.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
cp "$ROLE" "$WORK/role.yaml" 2>/dev/null || { echo "cannot measure: cannot copy $ROLE"; exit 2; }
rc=0

# Cell 0: the copy, unmutated, must pass — or every red below means nothing.
if out="$(check "$WORK/role.yaml")"; then
  echo "PASS  0 unmutated copy passes"
else
  echo "FAIL  0 unmutated copy does not pass:"; sed 's/^/        /' <<<"$out"; exit 1
fi

# name :: yq mutation :: text the failure must contain. Not `|`: yq
# expressions are pipelines, and the first version split them in half.
CASES=(
  "1 Flux API group (#190) :: .rules += [{\"apiGroups\": [\"kustomize.toolkit.fluxcd.io\"], \"resources\": [\"kustomizations\"], \"verbs\": [\"get\"]}] :: forbidden API group \"kustomize.toolkit.fluxcd.io\""
  "2 escalate (#190) :: (.rules[] | select(.resources | contains([\"roles\"])) | .verbs) += [\"escalate\"] :: verb escalate"
  "3 verbs * (#190) :: .rules[0].verbs = [\"*\"] :: verbs contains \"*\""
  "4 apiGroups * :: .rules[-1].apiGroups = [\"*\"] :: apiGroups contains \"*\""
  "5 resources * :: .rules[-1].resources = [\"*\"] :: resources contains \"*\""
  "6 bind :: (.rules[] | select(.resources | contains([\"roles\"])) | .verbs) += [\"bind\"] :: verb bind"
  "7 impersonate :: .rules += [{\"apiGroups\": [\"\"], \"resources\": [\"serviceaccounts\"], \"verbs\": [\"impersonate\"]}] :: verb impersonate"
  "8 cilium.io :: .rules += [{\"apiGroups\": [\"cilium.io\"], \"resources\": [\"ciliumnetworkpolicies\"], \"verbs\": [\"get\"]}] :: forbidden API group \"cilium.io\""
  "9 NetworkPolicy :: .rules += [{\"apiGroups\": [\"networking.k8s.io\"], \"resources\": [\"networkpolicies\"], \"verbs\": [\"create\"]}] :: networkpolicies"
  "10 storage.k8s.io :: .rules += [{\"apiGroups\": [\"storage.k8s.io\"], \"resources\": [\"storageclasses\"], \"verbs\": [\"get\"]}] :: forbidden API group \"storage.k8s.io\""
  "11 cluster-scoped namespaces :: .rules += [{\"apiGroups\": [\"\"], \"resources\": [\"namespaces\"], \"verbs\": [\"get\"]}] :: cluster-scoped kind namespaces"
  "12 quota writable :: (.rules[] | select(.resources | contains([\"resourcequotas\"])) | .verbs) += [\"update\"] :: write verb update on resourcequotas"
  "14 core cluster-scoped nodes :: (.rules[0].resources) += [\"nodes\"] :: cluster-scoped kind nodes (group \"core\")"
  "13 nonResourceURLs :: .rules += [{\"nonResourceURLs\": [\"/metrics\"], \"verbs\": [\"get\"]}] :: nonResourceURLs present"
)
for c in "${CASES[@]}"; do
  name="${c%% :: *}"; rest="${c#* :: }"; expr="${rest%% :: *}"; want="${rest#* :: }"
  cp "$WORK/role.yaml" "$WORK/m.yaml"
  yq -i "$expr" "$WORK/m.yaml" 2>"$WORK/err" || { echo "FAIL  $name: mutation did not apply ($(head -1 "$WORK/err"))"; rc=1; continue; }
  if cmp -s "$WORK/role.yaml" "$WORK/m.yaml"; then echo "FAIL  $name: mutation changed nothing"; rc=1; continue; fi
  out="$(check "$WORK/m.yaml")"; mrc=$?
  if [[ $mrc -eq 1 ]] && grep -qF -- "$want" <<<"$out"; then
    echo "PASS  $name  ->  $(grep -F -- "$want" <<<"$out" | head -1)"
  else
    echo "FAIL  $name: rc=$mrc, wanted 1 with \"$want\""; sed 's/^/        /' <<<"$out"; rc=1
  fi
done
[[ $rc -eq 0 ]] && echo "ok — self-test: unmutated passes, ${#CASES[@]} mutations each fail for their reason"
exit $rc
