#!/usr/bin/env bash
# Assert a tenant pod attaches a secondary network only with the l2 grant and
# only one defined in its own namespace, and never replaces the cluster network
# (ferry133/jg-base#187; fleet-ops root `standalone-app-repos` D9, task 8.1).
#
# Same harness as check-tenant-device-policy.sh: a real kube-apiserver (the
# envtest binaries, $KUBEBUILDER_ASSETS) and pods created against the policy
# as built from ./kubernetes/apps/base. The CEL is what a text check cannot
# judge — whether `split`/`trim`/`matches` behave on this apiserver, whether
# a second reference is walked, whether `default/` is caught. No CNI runs
# here; admission does not need one. Whether Multus attaches the interface is
# measured on a cluster (#187 acceptance), not here.
#
# Order matters for what a failure means. A canary policy is applied first and
# polled until it denies, so the admission plugin is known to be live; only
# then is the policy under test applied. A policy that loads late therefore
# shows up as a false RED, never as a false green — and "the policy never
# took effect" cannot be read as a pass.
#
# Usage: scripts/check-tenant-l2-policy.sh [--self-test]
#   exit 0 pass, 1 fail, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${KUBEBUILDER_ASSETS:-}"
for b in etcd kube-apiserver kubectl; do
  [[ -n "$ASSETS" && -x "$ASSETS/$b" ]] || { echo "cannot measure: \$KUBEBUILDER_ASSETS has no $b (envtest binaries)"; exit 2; }
done
for t in flux yq jq openssl curl; do command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }; done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tenant-l2.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
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
yq -o=json -I=0 'select((.kind == "ValidatingAdmissionPolicy" and .metadata.name == "tenant-l2-networks") or (.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == "tenant-l2-networks"))' \
  "$WORK/built.yaml" > "$WORK/policy.json"
[[ $(grep -c . "$WORK/policy.json") -eq 2 ]] || { echo "FAIL — the build does not hold exactly one tenant-l2-networks policy and one binding ($(grep -c . "$WORK/policy.json") documents)"; exit 1; }
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
pod() {  # ns name annotations-json
  jq -nc --arg ns "$1" --arg n "$2" --argjson a "$3" '
    {apiVersion:"v1",kind:"Pod",metadata:{namespace:$ns,name:$n,annotations:$a},
     spec:{automountServiceAccountToken:false,
           containers:[{name:"c",image:"busybox",
             securityContext:{runAsNonRoot:true,runAsUser:1000,allowPrivilegeEscalation:false,
                              capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}]}}' \
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
    [[ "$(k get validatingadmissionpolicy tenant-l2-networks -o jsonpath='{.status.observedGeneration}' 2>/dev/null)" == \
       "$(k get validatingadmissionpolicy tenant-l2-networks -o jsonpath='{.metadata.generation}' 2>/dev/null)" ]] && break
    sleep 1
  done
  local warn; warn=$(k get validatingadmissionpolicy tenant-l2-networks -o jsonpath='{.status.typeChecking.expressionWarnings}' 2>/dev/null)
  [[ -z "$warn" ]] || say "the policy's CEL has type-checking warnings: $warn"
  sleep 3

  ns plain jg.tenant=plain pod-security.kubernetes.io/enforce=restricted
  ns granted jg.tenant=granted jg.tenant-l2=granted pod-security.kubernetes.io/enforce=restricted
  ns notquite jg.tenant=notquite jg.tenant-l2=yes pod-security.kubernetes.io/enforce=restricted
  ns platform

  N='k8s.v1.cni.cncf.io/networks'; DN='v1.multus-cni.io/default-network'
  net() { jq -nc --arg k "$N" --arg v "$1" '{($k):$v}'; }
  denied() {  # label ns name annotations-json phrase
    out=$(pod "$2" "$3" "$4")
    # The pod must not exist. Matching the policy name and message alone also
    # matches a Warn binding, which prints both and then creates the pod.
    if ! grep -q "pod/$3 created" <<<"$out" && grep -q 'Forbidden' <<<"$out" \
       && grep -q 'tenant-l2-networks' <<<"$out" && grep -qF -- "$5" <<<"$out"; then
      echo "ok    $1 — denied: $(grep -o 'tenant "[a-z]*.*' <<<"$out" | head -1 | cut -c1-110)"
    else say "$1: expected the policy to deny with \"$5\", got: $out"; fi
  }
  admitted() {  # label ns name annotations-json
    out=$(pod "$2" "$3" "$4")
    if grep -q "pod/$3 created" <<<"$out"; then echo "ok    $1 — admitted"; else say "$1: expected admission, got: $out"; fi
  }
  denied   "no grant, own network"              plain    p1  "$(net lan)"                 "has no l2 grant"
  denied   "grant label not 'granted'"          notquite p2  "$(net lan)"                 "has no l2 grant"
  denied   "granted, other namespace"           granted  p3  "$(net other/lan)"           "only networks defined in its own namespace"
  denied   "granted, default namespace"         granted  p4  "$(net default/lan)"         "only networks defined in its own namespace"
  denied   "granted, second ref crosses"        granted  p5  "$(net 'lan, other/lan')"    "only networks defined in its own namespace"
  denied   "granted, JSON form"                 granted  p6  "$(net '[{"name":"lan"}]')"  "the JSON form is not accepted"
  denied   "granted, default-network override"  granted  p7  "$(jq -nc --arg k "$DN" '{($k):"lan"}')" "may not replace the cluster network"
  denied   "no grant, default-network override" plain    p8  "$(jq -nc --arg k "$DN" '{($k):"lan"}')" "may not replace the cluster network"
  admitted "granted, own network"               granted  p9  "$(net lan)"
  admitted "granted, own namespace and iface"   granted  p10 "$(net 'granted/lan@net1, lan2')"
  admitted "no grant, no annotations"           plain    p11 '{}'
  admitted "no grant, unrelated annotation"     plain    p12 '{"example.com/x":"y"}'
  admitted "platform namespace, cross ref"      platform p13 "$(net other/lan)"
  return $bad
}

if [[ "${1:-}" != "--self-test" ]]; then
  out="$(check "$WORK/policy.json")"; rc=$?
  echo "$out"
  [[ $rc -eq 0 ]] && echo "ok — on kube-apiserver $("$ASSETS/kube-apiserver" --version | cut -d' ' -f2): a tenant pod attaches a network only with jg.tenant-l2=granted, only from its own namespace (default/ included), only in the comma-separated form, and never replaces the cluster network; platform namespaces are not evaluated"
  exit $rc
fi

# ── self-test: each mutation must turn a specific cell red ──────────────────
out="$(check "$WORK/policy.json")"; rc=$?
if [[ $rc -eq 0 ]]; then echo "PASS  0 unmutated passes"; else echo "FAIL  0 unmutated rc=$rc:"; echo "$out"; exit 1; fi
P='(.kind=="ValidatingAdmissionPolicy")'
B='(.kind=="ValidatingAdmissionPolicyBinding")'
CASES=(
  "1 grant label presence only :: if $P then .spec.validations[1].expression = \"variables.networks == '' || 'jg.tenant-l2' in variables.nsLabels\" else . end :: grant label not 'granted'"
  "2 namespace not checked :: if $P then .spec.validations[3].expression = \"true\" else . end :: granted, other namespace"
  "3 default/ allowed :: if $P then .spec.validations[3].expression |= sub(\"r.split\\\\('/'\\\\)\\\\[0\\\\] == request.namespace\"; \"(r.split('/')[0] == request.namespace || r.split('/')[0] == 'default')\") else . end :: granted, default namespace"
  "4 first reference only :: if $P then .spec.validations[3].expression |= sub(\"variables.refs.all\"; \"[variables.refs[0]].all\") else . end :: granted, second ref crosses"
  "5 JSON form accepted :: if $P then .spec.validations[2].expression = \"true\" else . end :: granted, JSON form"
  "6 default-network ignored :: if $P then .spec.validations[0].expression = \"true\" else . end :: granted, default-network override"
  "7 match on networks only :: if $P then .spec.matchConditions[0].expression = \"has(object.metadata.annotations) && 'k8s.v1.cni.cncf.io/networks' in object.metadata.annotations\" else . end :: no grant, default-network override"
  "8 Warn not Deny :: if $B then .spec.validationActions = [\"Warn\"] else . end :: no grant, own network"
  "9 every namespace :: if $B then del(.spec.matchResources) else . end :: platform namespace, cross ref"
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
