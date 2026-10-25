#!/usr/bin/env bash
# Assert a tenant without the devices grant cannot get a device into a pod,
# and one with it can (ferry133/jg-base#188; fleet-ops root
# `standalone-app-repos` D9, task 8.2).
#
# Unlike check-tenant-lb-policy.sh this does not read the CEL as text: it runs
# a real kube-apiserver (the envtest binaries, $KUBEBUILDER_ASSETS: etcd,
# kube-apiserver, kubectl) and creates pods against the policy as built from
# ./kubernetes/apps/base. The CEL is the part a text check cannot judge —
# whether `requests.map(k, k)` yields names, whether a limit-only request is
# seen, whether init containers are walked.
#
# Order matters for what a failure means. A canary policy is applied first and
# polled until it denies, so the admission plugin is known to be live; only
# then is the policy under test applied. A policy that loads late therefore
# shows up as a false RED, never as a false green — and "the policy never
# took effect" cannot be read as a pass.
#
# Usage: scripts/check-tenant-device-policy.sh [--self-test]
#   exit 0 pass, 1 fail, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${KUBEBUILDER_ASSETS:-}"
for b in etcd kube-apiserver kubectl; do
  [[ -n "$ASSETS" && -x "$ASSETS/$b" ]] || { echo "cannot measure: \$KUBEBUILDER_ASSETS has no $b (envtest binaries)"; exit 2; }
done
for t in flux yq jq openssl curl; do command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }; done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant-dev.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

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
yq -o=json -I=0 'select((.kind == "ValidatingAdmissionPolicy" and .metadata.name == "tenant-device-requests") or (.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == "tenant-device-requests"))' \
  "$WORK/built.yaml" > "$WORK/policy.json"
[[ $(grep -c . "$WORK/policy.json") -eq 2 ]] || { echo "FAIL — the build does not hold exactly one tenant-device-requests policy and one binding ($(grep -c . "$WORK/policy.json") documents)"; exit 1; }
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
  k create namespace "$n" >/dev/null && { [[ $# -eq 0 ]] || k label namespace "$n" "$@" >/dev/null; } \
    && k -n "$n" create serviceaccount default >/dev/null
}
# A pod that PSA `restricted` admits, so a denial is the policy's and not PSA's.
pod() {  # ns name resources-json [init]
  local init="${4:-}" c
  c=$(jq -nc --argjson r "$3" '{name:"c",image:"busybox",resources:$r,
        securityContext:{runAsNonRoot:true,runAsUser:1000,allowPrivilegeEscalation:false,
                         capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}')
  jq -nc --arg ns "$1" --arg n "$2" --argjson c "$c" --arg init "$init" '
    {apiVersion:"v1",kind:"Pod",metadata:{namespace:$ns,name:$n},
     spec:{automountServiceAccountToken:false,
           containers:[ if $init == "" then $c else ($c|.resources={}) end ]}}
    | if $init == "" then . else .spec.initContainers = [$c|.name="i"] end' \
    > "$WORK/pod.json" || { echo "harness: could not build the pod"; return; }
  k create -f "$WORK/pod.json" 2>&1
}

# check POLICY_JSON -> lines; 0/1/2
check() {
  local pol="$1" d bad=0 out
  d="$(mktemp -d "$WORK/srv.XXXXXX")"
  start_apiserver "$d" || return 2
  say() { echo "FAIL — $1"; bad=1; }

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
    [[ "$(k get validatingadmissionpolicy tenant-device-requests -o jsonpath='{.status.observedGeneration}' 2>/dev/null)" == \
       "$(k get validatingadmissionpolicy tenant-device-requests -o jsonpath='{.metadata.generation}' 2>/dev/null)" ]] && break
    sleep 1
  done
  local warn; warn=$(k get validatingadmissionpolicy tenant-device-requests -o jsonpath='{.status.typeChecking.expressionWarnings}' 2>/dev/null)
  [[ -z "$warn" ]] || say "the policy's CEL has type-checking warnings: $warn"
  sleep 3

  ns plain jg.tenant=plain pod-security.kubernetes.io/enforce=restricted
  ns granted jg.tenant=granted jg.tenant-devices=granted pod-security.kubernetes.io/enforce=restricted
  ns notquite jg.tenant=notquite jg.tenant-devices=yes pod-security.kubernetes.io/enforce=restricted
  ns platform

  local SER='{"requests":{"devic.es/serial":"1"},"limits":{"devic.es/serial":"1"}}'
  denied() {  # label ns name res [init] -- wants a denial naming the resource
    out=$(pod "$2" "$3" "$4" "${5:-}")
    # The pod must not exist. Matching the policy name and message alone also
    # matches a Warn binding, which prints both and then creates the pod.
    if ! grep -q "pod/$3 created" <<<"$out" && grep -q 'Forbidden' <<<"$out" \
       && grep -q 'tenant-device-requests' <<<"$out" && grep -q "no devices grant" <<<"$out"; then
      grep -q "$6" <<<"$out" || say "$1: denied, but the message does not name $6: $out"
      echo "ok    $1 — denied: $(grep -o "tenant \"[a-z]*\" has no devices grant.*" <<<"$out" | head -1)"
    else say "$1: expected the policy to deny, got: $out"; fi
  }
  admitted() {  # label ns name res [init]
    out=$(pod "$2" "$3" "$4" "${5:-}")
    if grep -q "pod/$3 created" <<<"$out"; then echo "ok    $1 — admitted"; else say "$1: expected admission, got: $out"; fi
  }
  denied   "no grant, request+limit"        plain    p1 "$SER" "" "devic.es/serial"
  denied   "no grant, limit only"           plain    p2 '{"limits":{"devic.es/serial":"1"}}' "" "devic.es/serial"
  denied   "no grant, init container"       plain    p3 "$SER" init "devic.es/serial"
  denied   "no grant, another domain"       plain    p4 '{"limits":{"example.com/gpu":"1"}}' "" "example.com/gpu"
  denied   "grant label not 'granted'"      notquite p5 "$SER" "" "devic.es/serial"
  admitted "no grant, native resources"     plain    p6 '{"requests":{"cpu":"10m","memory":"8Mi","ephemeral-storage":"1Mi"},"limits":{"memory":"8Mi","hugepages-2Mi":"2Mi"}}'
  admitted "no grant, no resources"         plain    p7 '{}'
  admitted "granted, restricted PSA"        granted  p8 "$SER"
  admitted "granted, init container"        granted  p9 "$SER" init
  admitted "platform namespace"             platform p10 "$SER"
  return $bad
}

if [[ "${1:-}" != "--self-test" ]]; then
  out="$(check "$WORK/policy.json")"; rc=$?
  echo "$out"
  [[ $rc -eq 0 ]] && echo "ok — on kube-apiserver $("$ASSETS/kube-apiserver" --version | cut -d' ' -f2): a tenant without jg.tenant-devices=granted cannot request any extended resource (request, limit or init container); native resources, granted tenants and platform namespaces are admitted"
  exit $rc
fi

# ── self-test: each mutation must turn a specific cell red ──────────────────
out="$(check "$WORK/policy.json")"; rc=$?
if [[ $rc -eq 0 ]]; then echo "PASS  0 unmutated passes"; else echo "FAIL  0 unmutated rc=$rc:"; echo "$out"; exit 1; fi
P='(.kind=="ValidatingAdmissionPolicy")'
B='(.kind=="ValidatingAdmissionPolicyBinding")'
CONTAINERS="(object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : []))"
CASES=(
  # No "limits ignored" mutation: the policy reads requests only, and the
  # limit-only cell below proves that is enough (defaulting fills requests).
  "1 requests ignored :: if $P then .spec.matchConditions[0].expression = \"$CONTAINERS.exists(c, false)\" else . end :: no grant, limit only"
  "2 init containers ignored :: if $P then .spec.matchConditions[0].expression |= sub(\"\\\\+\\\\s*\\\\(has\\\\(object.spec.initContainers\\\\)[^)]*\\\\)\"; \"\") else . end :: no grant, init container"
  "3 only devic.es :: if $P then .spec.matchConditions[0].expression |= gsub(\"!\\\\(k in \\\\[[^]]*\\\\]\\\\) && !k.startsWith\\\\('hugepages-'\\\\)\"; \"k.startsWith('devic.es/')\") else . end :: no grant, another domain"
  "4 Warn not Deny :: if $B then .spec.validationActions = [\"Warn\"] else . end :: no grant, request+limit"
  "5 grant label presence only :: if $P then .spec.validations[0].expression = \"'jg.tenant-devices' in variables.nsLabels\" else . end :: grant label not 'granted'"
  "6 every namespace :: if $B then del(.spec.matchResources) else . end :: platform namespace"
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
