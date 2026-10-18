#!/usr/bin/env bash
# Assert the tenant HTTPRoute hostname policy, AS FLUX BUILDS IT, still bounds
# what jg-base#191 says it bounds (sub-change tenant-isolation-baseline §3,
# decision D-d; fleet-ops root `standalone-app-repos` D4).
#
# Read from `flux build` of kubernetes/apps/base, not from the source file,
# because the first version of this policy was correct in source and wrong as
# built: under flux-system/ it inherited `namespace: flux-system`, which
# kustomize v5.7.1 stamps onto ValidatingAdmissionPolicy(Binding) because it
# does not know they are cluster-scoped.
#
# What must hold, each a way the bound could quietly open:
#   - policy matches httproutes on CREATE *and* UPDATE (CREATE alone: edit a
#     compliant route to im.<domain> afterwards)
#   - failurePolicy Fail; binding validationActions [Deny] (Warn/Audit admit)
#   - binding selects namespaces with `jg.tenant` and nothing else (an empty
#     selector evaluates every route in the cluster; a missing one too)
#   - paramRef names the ConfigMap that exists in the build, in flux-system,
#     with parameterNotFoundAction Deny, and its domain is ${SECRET_DOMAIN}
#   - the CEL refuses empty hostnames and checks every hostname's suffix built
#     from the namespace's jg.tenant label and params.data.domain
#   - neither cluster-scoped kind carries a namespace
#
# Usage: scripts/check-tenant-hostname-policy.sh [--self-test]
#   exit 0 pass, 1 fail, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for t in flux yq jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant-hostname.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
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
# Positive control: the build is the base tree, not an empty or partial one.
grep -q '^  name: tenant-admin$' "$WORK/built.yaml" \
  || { echo "cannot measure: built output has no ClusterRole tenant-admin — not the base tree"; exit 2; }
yq -o=json -I=0 '.' "$WORK/built.yaml" > "$WORK/built.json" 2>/dev/null \
  || { echo "cannot measure: built output does not parse"; exit 2; }

# check JSONL -> FAIL lines; exit 0/1/2
check() {
  local f="$1" bad=0
  say() { echo "FAIL — $1"; bad=1; }
  local pol bind cm
  pol="$(jq -c 'select(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="tenant-httproute-hostnames")' "$f")"
  bind="$(jq -c 'select(.kind=="ValidatingAdmissionPolicyBinding" and .spec.policyName=="tenant-httproute-hostnames")' "$f")"
  [[ -n "$pol" ]] || { say "no ValidatingAdmissionPolicy tenant-httproute-hostnames in the build"; return 1; }
  [[ -n "$bind" ]] || { say "no binding with policyName tenant-httproute-hostnames in the build"; return 1; }
  [[ "$(wc -l <<<"$bind")" -eq 1 ]] || say "more than one binding for the policy"

  jq -e '.metadata.namespace == null' <<<"$pol" >/dev/null || say "the policy carries metadata.namespace (cluster-scoped kind got a namespace)"
  jq -e '.metadata.namespace == null' <<<"$bind" >/dev/null || say "the binding carries metadata.namespace (cluster-scoped kind got a namespace)"
  jq -e '.spec.failurePolicy == "Fail"' <<<"$pol" >/dev/null || say "failurePolicy is not Fail"
  jq -e '[.spec.matchConstraints.resourceRules[] | select((.apiGroups|index("gateway.networking.k8s.io")) and (.resources|index("httproutes")))] | length > 0' <<<"$pol" >/dev/null \
    || say "the policy does not match gateway.networking.k8s.io httproutes"
  for op in CREATE UPDATE; do
    jq -e --arg op "$op" '[.spec.matchConstraints.resourceRules[] | select(.resources|index("httproutes")) | .operations[]] | index($op)' <<<"$pol" >/dev/null \
      || say "the policy does not match operation $op"
  done
  local cel
  cel="$(jq -r '[.spec.variables[]?.expression, .spec.validations[]?.expression] | join(" ")' <<<"$pol")"
  grep -q "size(object.spec.hostnames) > 0" <<<"$cel" || say "the CEL does not refuse an empty hostnames list"
  grep -q "object.spec.hostnames.all(" <<<"$cel" || say "the CEL does not check every hostname"
  grep -q "endsWith(" <<<"$cel" || say "the CEL does not check a suffix"
  grep -q "namespaceObject.metadata.labels\['jg.tenant'\]" <<<"$cel" || say "the suffix is not built from the namespace's jg.tenant label"
  grep -q "params.data.domain" <<<"$cel" || say "the suffix is not built from params.data.domain"

  jq -e '.spec.validationActions == ["Deny"]' <<<"$bind" >/dev/null || say "binding validationActions is not exactly [Deny]"
  jq -e '.spec.matchResources.namespaceSelector.matchExpressions == [{"key":"jg.tenant","operator":"Exists"}]
         and (.spec.matchResources.namespaceSelector.matchLabels == null)' <<<"$bind" >/dev/null \
    || say "binding namespaceSelector is not exactly {jg.tenant Exists}"
  jq -e '.spec.paramRef.parameterNotFoundAction == "Deny"' <<<"$bind" >/dev/null || say "parameterNotFoundAction is not Deny"
  local pname pns
  pname="$(jq -r '.spec.paramRef.name // ""' <<<"$bind")"; pns="$(jq -r '.spec.paramRef.namespace // ""' <<<"$bind")"
  cm="$(jq -c --arg n "$pname" --arg ns "$pns" 'select(.kind=="ConfigMap" and .metadata.name==$n and .metadata.namespace==$ns)' "$f")"
  if [[ -z "$cm" ]]; then
    say "paramRef $pns/$pname names no ConfigMap in the build"
  else
    jq -e '.data.domain == "${SECRET_DOMAIN}"' <<<"$cm" >/dev/null || say "param ConfigMap domain is not \${SECRET_DOMAIN}"
    [[ "$pns" == "flux-system" ]] || say "param ConfigMap is in $pns, not flux-system"
  fi
  return $bad
}

if [[ "${1:-}" != "--self-test" ]]; then
  out="$(check "$WORK/built.json")"; rc=$?
  [[ -n "$out" ]] && echo "$out"
  [[ $rc -eq 0 ]] && echo "ok — tenant HTTPRoute hostname policy, as built: CREATE+UPDATE, Fail/Deny, jg.tenant namespaces only, param \${SECRET_DOMAIN} in flux-system with Deny when absent, no namespace on the cluster-scoped kinds"
  exit $rc
fi

# --- self-test: mutate the BUILT documents, each mutation must fail for its reason
if out="$(check "$WORK/built.json")"; then echo "PASS  0 unmutated build passes"; else echo "FAIL  0 unmutated build does not pass:"; echo "$out"; exit 1; fi
# Booleans, not select(): `if (select(…))` is EMPTY for every other document,
# and jq then drops them all — the first version of this self-test deleted the
# whole build on every case and read that as twelve different failures.
P='(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="tenant-httproute-hostnames")'
B='(.kind=="ValidatingAdmissionPolicyBinding" and .spec.policyName=="tenant-httproute-hostnames")'
C='(.kind=="ConfigMap" and .metadata.name=="tenant-hostname-params")'
CASES=(
  "1 CREATE only :: if $P then .spec.matchConstraints.resourceRules[0].operations = [\"CREATE\"] else . end :: does not match operation UPDATE"
  "2 failurePolicy Ignore :: if $P then .spec.failurePolicy = \"Ignore\" else . end :: failurePolicy is not Fail"
  "3 Warn instead of Deny :: if $B then .spec.validationActions = [\"Warn\"] else . end :: validationActions is not exactly [Deny]"
  "4 selector removed :: if $B then del(.spec.matchResources) else . end :: namespaceSelector is not exactly"
  "5 param absent allowed :: if $B then .spec.paramRef.parameterNotFoundAction = \"Allow\" else . end :: parameterNotFoundAction is not Deny"
  "6 param ConfigMap gone :: if $C then empty else . end :: names no ConfigMap in the build"
  "7 domain hardcoded :: if $C then .data.domain = \"jiahd.cc\" else . end :: domain is not"
  "8 empty hostnames allowed :: if $P then .spec.validations[0].expression = \"object.spec.hostnames.all(h, h.endsWith(variables.suffix))\" else . end :: does not refuse an empty hostnames list"
  "9 namespace on policy :: if $P then .metadata.namespace = \"flux-system\" else . end :: the policy carries metadata.namespace"
  "10 namespace on binding :: if $B then .metadata.namespace = \"flux-system\" else . end :: the binding carries metadata.namespace"
  "11 suffix not from label :: if $P then .spec.variables[0].expression = \"'.' + params.data.domain\" else . end :: not built from the namespace's jg.tenant label"
)
rc=0
for c in "${CASES[@]}"; do
  name="${c%% :: *}"; rest="${c#* :: }"; expr="${rest%% :: *}"; want="${rest#* :: }"
  jq -c "$expr" "$WORK/built.json" > "$WORK/m.json" 2>"$WORK/jqerr" || { echo "FAIL  $name: mutation did not apply ($(head -1 "$WORK/jqerr"))"; rc=1; continue; }
  if cmp -s "$WORK/built.json" "$WORK/m.json"; then echo "FAIL  $name: mutation changed nothing"; rc=1; continue; fi
  n0=$(wc -l < "$WORK/built.json"); n1=$(wc -l < "$WORK/m.json")
  if [[ "$expr" != *"then empty"* && $n0 -ne $n1 ]]; then echo "FAIL  $name: mutation changed the document count ($n0 -> $n1)"; rc=1; continue; fi
  out="$(check "$WORK/m.json")"; mrc=$?
  if [[ $mrc -eq 1 ]] && grep -qF -- "$want" <<<"$out"; then
    echo "PASS  $name  ->  $(grep -F -- "$want" <<<"$out" | head -1)"
  else
    echo "FAIL  $name: rc=$mrc, wanted 1 with \"$want\""; sed 's/^/        /' <<<"$out"; rc=1
  fi
done
[[ $rc -eq 0 ]] && echo "ok — self-test: unmutated build passes, ${#CASES[@]} mutations each fail for their reason"
exit $rc
