#!/usr/bin/env bash
# Assert a tenant HTTPRoute attaches only to network/envoy-internal, and to
# network/envoy-external only with jg.tenant-public=granted on its namespace
# (ferry133/jg-base#235; jgct#250 renders the label).
#
# Same harness as check-tenant-l2-policy.sh: a real kube-apiserver (the envtest
# binaries, $KUBEBUILDER_ASSETS) and routes written against the policy as built
# from ./kubernetes/apps/base. The routes need the HTTPRoute CRD; it is the
# Gateway API v1.4.1 experimental bundle, pinned by sha256 -- the bundle and
# channel jg-jcc2 runs (envoy-gateway's chart installs it there), and its
# parentRefs schema was compared byte-for-byte with jg-jcc2's on 2026-10-28.
# That matters: the CRD defaults `group` and `kind`, `namespace` it does not.
# Set GATEWAY_API_BUNDLE to a local copy to run offline; the sha256 still holds.
#
# Order matters for what a failure means: a canary policy must deny before the
# policy under test is applied, so "the policy never took effect" reads as RED.
#
# Usage: scripts/check-tenant-route-parents-policy.sh [--self-test]
#   exit 0 pass, 1 fail, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${KUBEBUILDER_ASSETS:-}"
for b in etcd kube-apiserver kubectl; do
  [[ -n "$ASSETS" && -x "$ASSETS/$b" ]] || { echo "cannot measure: \$KUBEBUILDER_ASSETS has no $b (envtest binaries)"; exit 2; }
done
for t in flux yq jq openssl curl shasum; do command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }; done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant-parents.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
POLICY=tenant-httproute-parents

# ── the HTTPRoute CRD ───────────────────────────────────────────────────────
GW_URL=https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml
GW_SHA256=553327e0ff32a1a2be446bf93823c8413cf9253ac6a6d5407eebd1e8d269f69e
if [[ -n "${GATEWAY_API_BUNDLE:-}" ]]; then cp "$GATEWAY_API_BUNDLE" "$WORK/gw.yaml" || { echo "cannot measure: GATEWAY_API_BUNDLE not readable"; exit 2; }
else curl -fsSL -o "$WORK/gw.yaml" "$GW_URL" || { echo "cannot measure: could not download $GW_URL"; exit 2; }; fi
[[ "$(shasum -a 256 "$WORK/gw.yaml" | cut -d' ' -f1)" == "$GW_SHA256" ]] || { echo "cannot measure: Gateway API bundle sha256 mismatch"; exit 2; }
yq 'select(.kind == "CustomResourceDefinition" and .metadata.name == "httproutes.gateway.networking.k8s.io")' "$WORK/gw.yaml" > "$WORK/crd.yaml"
grep -q '^kind: CustomResourceDefinition' "$WORK/crd.yaml" || { echo "cannot measure: no httproutes CRD in the bundle"; exit 2; }

# ── the policy, as built ────────────────────────────────────────────────────
cat > "$WORK/ks.yaml" <<'KS'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: cluster-apps-base, namespace: flux-system}
spec: {interval: 1h, path: ./kubernetes/apps/base, prune: true, sourceRef: {kind: GitRepository, name: jg-base}}
KS
( cd "$ROOT" && flux build kustomization cluster-apps-base --path ./kubernetes/apps/base \
    --kustomization-file "$WORK/ks.yaml" --dry-run ) > "$WORK/built.yaml" 2>"$WORK/err" \
  || { echo "cannot measure: flux build failed: $(head -2 "$WORK/err")"; exit 2; }
grep -q '^  name: tenant-admin$' "$WORK/built.yaml" || { echo "cannot measure: built output has no tenant-admin — not the base tree"; exit 2; }
yq -o=json -I=0 "select((.kind == \"ValidatingAdmissionPolicy\" and .metadata.name == \"$POLICY\") or (.kind == \"ValidatingAdmissionPolicyBinding\" and .spec.policyName == \"$POLICY\"))" \
  "$WORK/built.yaml" > "$WORK/policy.json"
[[ $(grep -c . "$WORK/policy.json") -eq 2 ]] || { echo "FAIL — the build does not hold exactly one $POLICY policy and one binding ($(grep -c . "$WORK/policy.json") documents)"; exit 1; }
jq -e 'select(.metadata.namespace != null)' "$WORK/policy.json" >/dev/null && { echo "FAIL — a cluster-scoped policy object carries metadata.namespace in the build"; exit 1; }

# ── a throwaway apiserver ───────────────────────────────────────────────────
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
start_apiserver() {  # $1 = dir; sets KC
  local d="$1" ep cp ap; mkdir -p "$d/etcd" "$d/certs"
  ep=$(port); cp=$(port); ap=$(port)
  "$ASSETS/etcd" --data-dir "$d/etcd" --listen-client-urls "http://127.0.0.1:$ep" \
    --advertise-client-urls "http://127.0.0.1:$ep" --listen-peer-urls "http://127.0.0.1:$cp" \
    --initial-advertise-peer-urls "http://127.0.0.1:$cp" --initial-cluster "default=http://127.0.0.1:$cp" \
    --unsafe-no-fsync >"$d/etcd.log" 2>&1 & PIDS+=($!)
  openssl genrsa -out "$d/sa.key" 2048 2>/dev/null
  echo "t0ken,admin,admin,system:masters" > "$d/tokens.csv"
  "$ASSETS/kube-apiserver" --etcd-servers "http://127.0.0.1:$ep" --cert-dir "$d/certs" \
    --secure-port "$ap" --bind-address 127.0.0.1 --token-auth-file "$d/tokens.csv" \
    --authorization-mode RBAC --service-cluster-ip-range 10.0.0.0/24 \
    --service-account-issuer https://kubernetes.default.svc --service-account-key-file "$d/sa.key" \
    --service-account-signing-key-file "$d/sa.key" >"$d/apiserver.log" 2>&1 & PIDS+=($!)
  KC="$d/kubeconfig"
  "$ASSETS/kubectl" config --kubeconfig "$KC" set-cluster t --server "https://127.0.0.1:$ap" --insecure-skip-tls-verify=true >/dev/null
  "$ASSETS/kubectl" config --kubeconfig "$KC" set-credentials t --token t0ken >/dev/null
  "$ASSETS/kubectl" config --kubeconfig "$KC" set-context t --cluster t --user t >/dev/null
  "$ASSETS/kubectl" config --kubeconfig "$KC" use-context t >/dev/null
  local i; for i in $(seq 1 60); do
    "$ASSETS/kubectl" --kubeconfig "$KC" get --raw /readyz >/dev/null 2>&1 && return 0; sleep 1
  done
  echo "cannot measure: kube-apiserver not ready in 60s: $(tail -2 "$d/apiserver.log")"; return 2
}
k() { "$ASSETS/kubectl" --kubeconfig "$KC" "$@"; }

ns() {  # name labels...
  local n="$1"; shift
  k create namespace "$n" >/dev/null && { [[ $# -eq 0 ]] || k label namespace "$n" "$@" >/dev/null; }
}
# route NS NAME PARENTREFS-JSON (null = no parentRefs) -> kubectl output
route() {
  jq -nc --arg ns "$1" --arg n "$2" --argjson p "$3" '
    {apiVersion:"gateway.networking.k8s.io/v1",kind:"HTTPRoute",metadata:{namespace:$ns,name:$n},
     spec:({hostnames:["x.example.test"]} + (if $p == null then {} else {parentRefs:$p} end))}' \
    > "$WORK/route.json" || { echo "harness: could not build the route"; return; }
  k create -f "$WORK/route.json" 2>&1
}
gw() { jq -nc --arg n "$1" '{namespace:"network",name:$n}'; }   # the usual spelling

# check POLICY_JSON -> lines; 0/1/2
check() {
  local pol="$1" d bad=0 out
  d="$(mktemp -d "$WORK/srv.XXXXXX")"
  start_apiserver "$d" || return 2
  say() { echo "FAIL — $1"; bad=1; }

  k create -f "$WORK/crd.yaml" >/dev/null 2>"$WORK/crd.err" || { echo "cannot measure: HTTPRoute CRD did not apply: $(head -1 "$WORK/crd.err")"; return 2; }
  k wait --for=condition=Established --timeout=60s crd/httproutes.gateway.networking.k8s.io >/dev/null 2>&1 \
    || { echo "cannot measure: HTTPRoute CRD never Established"; return 2; }

  # Canary first: once it denies, validating admission policies are live.
  cat <<'CANARY' | k apply -f - >/dev/null || { echo "cannot measure: canary did not apply"; return 2; }
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: canary}
spec:
  failurePolicy: Fail
  matchConstraints: {resourceRules: [{apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [configmaps]}]}
  validations: [{expression: "false", message: canary}]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: canary}
spec: {policyName: canary, validationActions: [Deny]}
CANARY
  local i live=0
  for i in $(seq 1 30); do
    out=$(k -n default create configmap "c$i" 2>&1)
    if grep -q 'canary' <<<"$out"; then live=1; break; fi
    k -n default delete configmap "c$i" >/dev/null 2>&1; sleep 1
  done
  (( live )) || { echo "cannot measure: the canary policy never denied — admission policies are not live here"; return 2; }

  k apply -f "$pol" >/dev/null 2>"$WORK/apply.err" || { say "the policy does not apply: $(head -2 "$WORK/apply.err")"; return 1; }
  for i in $(seq 1 20); do
    [[ "$(k get validatingadmissionpolicy $POLICY -o jsonpath='{.status.observedGeneration}' 2>/dev/null)" == \
       "$(k get validatingadmissionpolicy $POLICY -o jsonpath='{.metadata.generation}' 2>/dev/null)" ]] && break
    sleep 1
  done
  local warn; warn=$(k get validatingadmissionpolicy $POLICY -o jsonpath='{.status.typeChecking.expressionWarnings}' 2>/dev/null)
  [[ -z "$warn" ]] || say "the policy's CEL has type-checking warnings: $warn"
  sleep 3

  ns network
  ns plain jg.tenant=plain
  ns pub jg.tenant=pub jg.tenant-public=granted
  ns notquite jg.tenant=notquite jg.tenant-public=yes
  ns platform

  # The route must not exist: matching the message alone also matches a Warn
  # binding, which prints it and then creates the route.
  denied() {  # label ns name parentrefs-json phrase
    out=$(route "$2" "$3" "$4")
    if ! grep -q "httproute.gateway.networking.k8s.io/$3 created" <<<"$out" && grep -q 'Forbidden' <<<"$out" \
       && grep -q "$POLICY" <<<"$out" && grep -qF -- "$5" <<<"$out"; then
      echo "ok    $1 — denied: $(grep -o 'tenant "[a-z]*.*' <<<"$out" | head -1 | cut -c1-120)"
    else say "$1: expected the policy to deny with \"$5\", got: $out"; fi
  }
  admitted() {  # label ns name parentrefs-json
    out=$(route "$2" "$3" "$4")
    if grep -q "httproute.gateway.networking.k8s.io/$3 created" <<<"$out"; then echo "ok    $1 — admitted"; else say "$1: expected admission, got: $out"; fi
  }
  INT="[$(gw envoy-internal)]"; EXT="[$(gw envoy-external)]"
  denied   "no grant, envoy-external"              plain    r1  "$EXT"   "needs the public grant"
  denied   "grant label not 'granted'"             notquite r2  "$EXT"   "needs the public grant"
  denied   "no grant, second ref external"         plain    r3  "[$(gw envoy-internal),$(gw envoy-external)]" "got network/Gateway/envoy-internal, network/Gateway/envoy-external"
  denied   "namespace omitted (route's own)"       plain    r4  '[{"name":"envoy-internal"}]' "got plain/Gateway/envoy-internal"
  denied   "granted, a gateway not on the list"    pub      r5  "[$(gw envoy-staging)]" "got network/Gateway/envoy-staging"
  # One property wrong per cell: a cell wrong in two is caught by either check
  # and so tells neither apart (a kind cell with group "" survived mutation 2).
  denied   "kind not Gateway"                      plain    r6  '[{"group":"gateway.networking.k8s.io","kind":"ListenerSet","namespace":"network","name":"envoy-internal"}]' "got network/ListenerSet/envoy-internal"
  denied   "group not gateway.networking.k8s.io"   plain    r7  '[{"group":"example.com","kind":"Gateway","namespace":"network","name":"envoy-internal"}]' "got network/Gateway/envoy-internal"
  admitted "no grant, envoy-internal"              plain    r8  "$INT"
  admitted "no grant, internal with section/port"  plain    r9  '[{"namespace":"network","name":"envoy-internal","sectionName":"https","port":443}]'
  admitted "granted, envoy-external"               pub      r10 "$EXT"
  admitted "granted, both gateways"                pub      r11 "[$(gw envoy-internal),$(gw envoy-external)]"
  admitted "no grant, no parentRefs"               plain    r12 null
  admitted "platform namespace, envoy-external"    platform r13 "$EXT"

  # UPDATE: the compliant r8 edited to envoy-external must be refused and stay
  # as it was; an edit that keeps envoy-internal is the positive control.
  out=$(k -n plain patch httproute r8 --type=merge -p "{\"spec\":{\"parentRefs\":$EXT}}" 2>&1)
  if grep -q 'Forbidden' <<<"$out" && grep -q "$POLICY" <<<"$out" \
     && [[ "$(k -n plain get httproute r8 -o jsonpath='{.spec.parentRefs[0].name}')" == envoy-internal ]]; then
    echo "ok    UPDATE internal -> external — denied, route unchanged"
  else say "UPDATE internal -> external: expected a denial and r8 still on envoy-internal, got: $out"; fi
  out=$(k -n plain patch httproute r8 --type=merge -p '{"spec":{"hostnames":["y.example.test"]}}' 2>&1)
  if grep -q 'patched' <<<"$out"; then echo "ok    UPDATE keeping envoy-internal — admitted"
  else say "UPDATE keeping envoy-internal: expected admission, got: $out"; fi
  return $bad
}

if [[ "${1:-}" != "--self-test" ]]; then
  out="$(check "$WORK/policy.json")"; rc=$?
  echo "$out"
  [[ $rc -eq 0 ]] && echo "ok — on kube-apiserver $("$ASSETS/kube-apiserver" --version | cut -d' ' -f2) with Gateway API v1.4.1: a tenant HTTPRoute attaches only to network/envoy-internal, also to network/envoy-external with jg.tenant-public=granted, on CREATE and UPDATE, every parentRef resolved (namespace, group, kind); platform namespaces are not evaluated"
  exit $rc
fi

# ── self-test: each mutation must turn a specific cell red ──────────────────
out="$(check "$WORK/policy.json")"; rc=$?
if [[ $rc -eq 0 ]]; then echo "PASS  0 unmutated passes"; else echo "FAIL  0 unmutated rc=$rc:"; echo "$out"; exit 1; fi
P='(.kind=="ValidatingAdmissionPolicy")'
B='(.kind=="ValidatingAdmissionPolicyBinding")'
V='.spec.validations[0].expression'
CASES=(
  "1 namespace defaults to network :: if $P then $V |= sub(\": object.metadata.namespace\\\\) == 'network'\"; \": 'network') == 'network'\") else . end :: namespace omitted (route's own)"
  "2 kind not checked :: if $P then $V |= sub(\"\\\\(has\\\\(p.kind\\\\) \\\\? p.kind : 'Gateway'\\\\) == 'Gateway' &&\"; \"\") else . end :: kind not Gateway"
  "3 group not checked :: if $P then $V |= sub(\"\\\\(has\\\\(p.group\\\\) \\\\? p.group : 'gateway.networking.k8s.io'\\\\) == 'gateway.networking.k8s.io' &&\"; \"\") else . end :: group not gateway.networking.k8s.io"
  "4 grant label presence only :: if $P then .spec.variables |= map(if .name == \"public\" then .expression = \"'jg.tenant-public' in variables.nsLabels\" else . end) else . end :: grant label not 'granted'"
  "5 first parentRef only :: if $P then $V |= sub(\"variables.parents.all\"; \"(size(variables.parents) > 0 ? [variables.parents[0]] : []).all\") else . end :: no grant, second ref external"
  "6 prefix, not allow-list :: if $P then $V |= sub(\"p.name in variables.allowed\"; \"p.name.startsWith('envoy-') && (variables.public || p.name != 'envoy-external')\") else . end :: granted, a gateway not on the list"
  "7 CREATE only :: if $P then .spec.matchConstraints.resourceRules[0].operations = [\"CREATE\"] else . end :: UPDATE internal -> external"
  "8 Warn not Deny :: if $B then .spec.validationActions = [\"Warn\"] else . end :: no grant, envoy-external"
  "9 every namespace :: if $B then del(.spec.matchResources) else . end :: platform namespace, envoy-external"
  "10 grant ignored :: if $P then .spec.variables |= map(if .name == \"public\" then .expression = \"true\" else . end) else . end :: no grant, envoy-external"
)
rc=0
for c in "${CASES[@]}"; do
  name="${c%% :: *}"; r="${c#* :: }"; expr="${r%% :: *}"; want="${r#* :: }"
  jq -c "$expr" "$WORK/policy.json" > "$WORK/m.json" 2>"$WORK/e" || { echo "FAIL  $name: mutation did not apply ($(head -1 "$WORK/e"))"; rc=1; continue; }
  cmp -s "$WORK/policy.json" "$WORK/m.json" && { echo "FAIL  $name: mutation changed nothing"; rc=1; continue; }
  out="$(check "$WORK/m.json")"; mrc=$?
  if [[ $mrc -eq 1 ]] && grep -F -- "FAIL — $want" <<<"$out" >/dev/null; then
    echo "PASS  $name  ->  $(grep -F -- "FAIL — $want" <<<"$out" | head -1 | cut -c1-120)"
  else
    echo "FAIL  $name: rc=$mrc, wanted 1 with a failure on \"$want\""; sed 's/^/        /' <<<"$out"; rc=1
  fi
done
[[ $rc -eq 0 ]] && echo "ok — self-test: unmutated passes, ${#CASES[@]} mutations each fail on their cell"
exit $rc
