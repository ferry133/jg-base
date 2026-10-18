#!/usr/bin/env bash
# Assert a tenant LoadBalancer Service can never take a platform address
# (ferry133/jg-base#192; fleet-ops root `standalone-app-repos` D9 option (B);
# sub-change tenant-isolation-baseline §3b).
#
# Three places must agree, and each is read where it takes effect:
#   1. every static CiliumLoadBalancerIPPool under kubernetes/ excludes
#      Services labelled `jg.tenant` (DoesNotExist) — today that is `pool`;
#   2. the pools lan-address publishes AT RUNTIME on an appliance: its
#      selector_yaml function is extracted from the ConfigMap and EXECUTED for
#      both roles, and the YAML it prints must exclude `jg.tenant`;
#   3. the admission policy that makes the label trustworthy, as built: on
#      services CREATE+UPDATE, only for type LoadBalancer, requiring the
#      namespace's `jg.tenant-lan-ip: granted` and the Service's `jg.tenant`
#      equal to the namespace's; Fail; bound with [Deny] to `jg.tenant`
#      namespaces only; no namespace on either cluster-scoped kind.
#
# Usage: scripts/check-tenant-lb-policy.sh [--self-test]
#   exit 0 pass, 1 fail, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/network/lan-address/app/configmap.yaml"
for t in flux yq jq; do command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }; done
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant-lb.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ks.yaml" <<'KS'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: cluster-apps-base, namespace: flux-system}
spec: {interval: 1h, path: ./kubernetes/apps/base, prune: true, sourceRef: {kind: GitRepository, name: jg-base}}
KS
( cd "$ROOT" && flux build kustomization cluster-apps-base --path ./kubernetes/apps/base \
    --kustomization-file "$WORK/ks.yaml" --dry-run ) > "$WORK/built.yaml" 2>"$WORK/err" \
  || { echo "cannot measure: flux build failed: $(head -2 "$WORK/err")"; exit 2; }
yq -o=json -I=0 '.' "$WORK/built.yaml" > "$WORK/built.json" 2>/dev/null || { echo "cannot measure: built output does not parse"; exit 2; }
grep -q '"name":"tenant-admin"' "$WORK/built.json" || { echo "cannot measure: built output has no tenant-admin — not the base tree"; exit 2; }
# Pools are NOT in that build: each lives in an app directory applied by its own
# Flux Kustomization (cilium's networks.yaml). So every static pool anywhere
# under kubernetes/ is collected and appended, one JSON document per line.
find "$ROOT/kubernetes" -name '*.yaml' -print0 \
  | xargs -0 grep -l '^kind: CiliumLoadBalancerIPPool' 2>/dev/null \
  | while read -r f; do yq -o=json -I=0 'select(.kind == "CiliumLoadBalancerIPPool")' "$f"; done >> "$WORK/built.json"
# Positive control: the shared pool was found at all.
jq -e 'select(.kind=="CiliumLoadBalancerIPPool" and .metadata.name=="pool")' "$WORK/built.json" >/dev/null \
  || { echo "cannot measure: no CiliumLoadBalancerIPPool 'pool' under kubernetes/ — wrong tree or wrong reader"; exit 2; }

# The function, as the probe script defines it (the ConfigMap's script is
# indented four spaces under `data:`).
extract_selector() {
  yq -r '.data | to_entries | .[].value' "$1" 2>/dev/null | awk '
    /^selector_yaml\(\) \{/ { on = 1 }
    on { print }
    on && /^\}/ { exit }'
}
extract_selector "$CM" > "$WORK/selector.sh"
grep -q '^selector_yaml() {' "$WORK/selector.sh" || { echo "cannot measure: selector_yaml not found in $CM"; exit 2; }

# check BUILT_JSON SELECTOR_SH -> FAIL lines; 0/1/2
check() {
  local f="$1" sel="$2" bad=0
  say() { echo "FAIL — $1"; bad=1; }
  local exclude='[.spec.serviceSelector.matchExpressions[]? | select(.key=="jg.tenant" and .operator=="DoesNotExist")] | length == 1'
  local pools
  pools="$(jq -r 'select(.kind=="CiliumLoadBalancerIPPool") | .metadata.name' "$f")"
  [[ -n "$pools" ]] || say "no CiliumLoadBalancerIPPool found"
  for p in $pools; do
    jq -e --arg p "$p" "select(.kind==\"CiliumLoadBalancerIPPool\" and .metadata.name==\$p) | $exclude" "$f" >/dev/null \
      || say "pool $p does not exclude jg.tenant Services (DoesNotExist)"
  done

  local role out
  for role in external shared; do
    out="$(EXTERNAL_SELECTOR_KEY=io.kubernetes.service.name EXTERNAL_GATEWAY=envoy-external \
           bash -c ". '$sel'; selector_yaml $role" 2>&1)" || { say "selector_yaml $role did not run: $out"; continue; }
    printf 'spec:\n%s' "$out" | yq -o=json -I=0 '.' 2>/dev/null > "$WORK/sel-$role.json" \
      || { say "selector_yaml $role prints YAML that does not parse"; continue; }
    jq -e "$exclude" "$WORK/sel-$role.json" >/dev/null || say "lan-address $role pool does not exclude jg.tenant Services"
  done
  # The external role must keep selecting envoy-external (the exclusion is an
  # addition, not a replacement).
  jq -e '.spec.serviceSelector.matchLabels["io.kubernetes.service.name"] == "envoy-external"' "$WORK/sel-external.json" >/dev/null 2>&1 \
    || say "lan-address external pool no longer selects envoy-external"

  local pol bind
  pol="$(jq -c 'select(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="tenant-loadbalancer-services")' "$f")"
  bind="$(jq -c 'select(.kind=="ValidatingAdmissionPolicyBinding" and .spec.policyName=="tenant-loadbalancer-services")' "$f")"
  [[ -n "$pol" ]] || { say "no ValidatingAdmissionPolicy tenant-loadbalancer-services in the build"; return 1; }
  [[ -n "$bind" ]] || { say "no binding for tenant-loadbalancer-services in the build"; return 1; }
  jq -e '.metadata.namespace == null' <<<"$pol" >/dev/null || say "the policy carries metadata.namespace"
  jq -e '.metadata.namespace == null' <<<"$bind" >/dev/null || say "the binding carries metadata.namespace"
  jq -e '.spec.failurePolicy == "Fail"' <<<"$pol" >/dev/null || say "failurePolicy is not Fail"
  for op in CREATE UPDATE; do
    jq -e --arg op "$op" '[.spec.matchConstraints.resourceRules[] | select((.apiGroups|index("")) and (.resources|index("services"))) | .operations[]] | index($op)' <<<"$pol" >/dev/null \
      || say "the policy does not match core services on $op"
  done
  jq -e '[.spec.matchConditions[]?.expression] | any(test("object.spec.type == .LoadBalancer."))' <<<"$pol" >/dev/null \
    || say "the policy is not limited to type LoadBalancer"
  local cel; cel="$(jq -r '[.spec.variables[]?.expression, .spec.validations[]?.expression] | join(" ")' <<<"$pol")"
  grep -q "'jg.tenant-lan-ip' in variables.nsLabels" <<<"$cel" && grep -q "variables.nsLabels\['jg.tenant-lan-ip'\] == 'granted'" <<<"$cel" \
    || say "the policy does not require the namespace's jg.tenant-lan-ip: granted"
  grep -q "variables.svcLabels\['jg.tenant'\] == variables.tenant" <<<"$cel" \
    || say "the policy does not require the Service's jg.tenant to equal the namespace's"
  grep -q "namespaceObject.metadata.labels\['jg.tenant'\]" <<<"$cel" || say "the tenant is not read from the namespace label"
  jq -e '.spec.validationActions == ["Deny"]' <<<"$bind" >/dev/null || say "binding validationActions is not exactly [Deny]"
  jq -e '.spec.matchResources.namespaceSelector.matchExpressions == [{"key":"jg.tenant","operator":"Exists"}]
         and (.spec.matchResources.namespaceSelector.matchLabels == null)' <<<"$bind" >/dev/null \
    || say "binding namespaceSelector is not exactly {jg.tenant Exists}"
  return $bad
}

if [[ "${1:-}" != "--self-test" ]]; then
  out="$(check "$WORK/built.json" "$WORK/selector.sh")"; rc=$?
  [[ -n "$out" ]] && echo "$out"
  [[ $rc -eq 0 ]] && echo "ok — every static pool under kubernetes/ and both lan-address pools exclude jg.tenant; the LoadBalancer policy (CREATE+UPDATE, Fail, Deny, jg.tenant namespaces) requires the grant and the matching label"
  exit $rc
fi

if out="$(check "$WORK/built.json" "$WORK/selector.sh")"; then echo "PASS  0 unmutated passes"; else echo "FAIL  0 unmutated does not pass:"; echo "$out"; exit 1; fi
P='(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="tenant-loadbalancer-services")'
B='(.kind=="ValidatingAdmissionPolicyBinding" and .spec.policyName=="tenant-loadbalancer-services")'
L='(.kind=="CiliumLoadBalancerIPPool" and .metadata.name=="pool")'
# name :: target (json|sel) :: mutation (jq for json, sed for sel) :: expected text
CASES=(
  "1 shared pool without exclusion :: json :: if $L then del(.spec.serviceSelector) else . end :: pool pool does not exclude"
  "2 exclusion as Exists :: json :: if $L then .spec.serviceSelector.matchExpressions[0].operator = \"Exists\" else . end :: pool pool does not exclude"
  "3 lan-address shared role :: sel :: s/values: \[\"%s\"\]\\\\n      - key: jg.tenant\\\\n        operator: DoesNotExist\\\\n/values: [\"%s\"]\\\\n/ :: lan-address shared pool does not exclude"
  "4 lan-address external role :: sel :: s/\"%s\"\\\\n    matchExpressions:\\\\n      - key: jg.tenant\\\\n        operator: DoesNotExist\\\\n/\"%s\"\\\\n/ :: lan-address external pool does not exclude"
  "5 CREATE only :: json :: if $P then .spec.matchConstraints.resourceRules[0].operations = [\"CREATE\"] else . end :: does not match core services on UPDATE"
  "6 every Service type :: json :: if $P then del(.spec.matchConditions) else . end :: not limited to type LoadBalancer"
  "7 no grant check :: json :: if $P then .spec.validations |= .[1:] else . end :: does not require the namespace's jg.tenant-lan-ip"
  "8 no label check :: json :: if $P then .spec.validations |= .[:1] else . end :: Service's jg.tenant to equal"
  "9 Warn :: json :: if $B then .spec.validationActions = [\"Warn\"] else . end :: validationActions is not exactly [Deny]"
  "10 all namespaces :: json :: if $B then del(.spec.matchResources) else . end :: namespaceSelector is not exactly"
  "11 failurePolicy Ignore :: json :: if $P then .spec.failurePolicy = \"Ignore\" else . end :: failurePolicy is not Fail"
  "12 namespace on policy :: json :: if $P then .metadata.namespace = \"flux-system\" else . end :: the policy carries metadata.namespace"
)
rc=0
for c in "${CASES[@]}"; do
  name="${c%% :: *}"; r1="${c#* :: }"; target="${r1%% :: *}"; r2="${r1#* :: }"; expr="${r2%% :: *}"; want="${r2#* :: }"
  cp "$WORK/built.json" "$WORK/m.json"; cp "$WORK/selector.sh" "$WORK/m.sh"
  if [[ "$target" == json ]]; then
    jq -c "$expr" "$WORK/built.json" > "$WORK/m.json" 2>"$WORK/e" || { echo "FAIL  $name: mutation did not apply ($(head -1 "$WORK/e"))"; rc=1; continue; }
    [[ $(wc -l < "$WORK/m.json") -eq $(wc -l < "$WORK/built.json") ]] || { echo "FAIL  $name: mutation changed the document count"; rc=1; continue; }
  else
    sed "$expr" "$WORK/selector.sh" > "$WORK/m.sh"
  fi
  if cmp -s "$WORK/built.json" "$WORK/m.json" && cmp -s "$WORK/selector.sh" "$WORK/m.sh"; then echo "FAIL  $name: mutation changed nothing"; rc=1; continue; fi
  out="$(check "$WORK/m.json" "$WORK/m.sh")"; mrc=$?
  if [[ $mrc -eq 1 ]] && grep -qF -- "$want" <<<"$out"; then
    echo "PASS  $name  ->  $(grep -F -- "$want" <<<"$out" | head -1)"
  else
    echo "FAIL  $name: rc=$mrc, wanted 1 with \"$want\""; sed 's/^/        /' <<<"$out"; rc=1
  fi
done
[[ $rc -eq 0 ]] && echo "ok — self-test: unmutated passes, ${#CASES[@]} mutations each fail for their reason"
exit $rc
