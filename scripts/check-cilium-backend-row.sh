#!/usr/bin/env bash
# Assert that daily-check row 27 (Cilium service backends vs EndpointSlice,
# ferry133/jg-base#159) gives every verdict it claims, from the real block.
#
# The defect it exists for: jg-jiahd `.21`'s agent held a third kube-dns
# backend no EndpointSlice had, black-holing a third of DNS while every API
# object read healthy (ferry133/jg-jiahd#5). So the first case is that state.
#
# The kubectl stub answers ONLY the three calls the row makes and fails loudly
# on anything else: a stub that ignores its arguments is a constant, not a
# stand-in, and a row reading the wrong object would pass against it.
#
# Usage: scripts/check-cilium-backend-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cannot measure: jq is missing"; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cilium-row.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# From the row's own header to the next header or the report assembly.
BLOCK="$(awk '
    /^[[:space:]]*# 27\. Cilium service backends/ { grabbing = 1; next }
    grabbing && /^[[:space:]]*# [0-9]+[a-z]?\. / { exit }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: row 27 was not found in the ConfigMap"; exit 2; }
grep -q 'cilium-dbg service list -o json' <<<"$BLOCK" || { echo "cannot measure: extracted block is not row 27"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# --- fixtures ---------------------------------------------------------------
# svc <name> <ns> <policy> <ip:port[:state]>...   → one agent service entry
svc() {
  local name="$1" ns="$2" pol="$3"; shift 3
  local b="[]" x ip port st
  for x in "$@"; do
    IFS=: read -r ip port st <<<"$x"
    b=$(jq -c --arg ip "$ip" --argjson p "$port" --arg s "${st:-active}" '. + [{ip:$ip,port:$p,state:$s,protocol:"UDP"}]' <<<"$b")
  done
  jq -nc --arg n "$name" --arg ns "$ns" --arg pol "$pol" --argjson b "$b" \
    '{spec:{flags:{type:"ClusterIP",name:$n,namespace:$ns,intTrafficPolicy:$pol},"backend-addresses":$b}}'
}
# eps <name> <ns> <port> <ip:node:ready>...       → one EndpointSlice
eps() {
  local name="$1" ns="$2" port="$3"; shift 3
  local e="[]" x ip node rd
  for x in "$@"; do
    IFS=: read -r ip node rd <<<"$x"
    e=$(jq -c --arg ip "$ip" --arg nd "$node" --argjson r "$rd" '. + [{addresses:[$ip],nodeName:$nd,conditions:{ready:$r}}]' <<<"$e")
  done
  jq -nc --arg n "$name" --arg ns "$ns" --argjson p "$port" --argjson e "$e" \
    '{addressType:"IPv4",metadata:{namespace:$ns,labels:{"kubernetes.io/service-name":$n}},ports:[{port:$p}],endpoints:$e}'
}
list()  { jq -sc '.' ; }                       # objects on stdin → JSON array
items() { jq -sc '{items:.}' ; }               # objects on stdin → {items:[…]}

DNS_OK="$(svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53)"
EPS_OK="$( { eps kube-dns kube-system 53 10.0.0.62:n1:true 10.0.2.162:n2:true; } | items)"
PODS2="$(jq -nc '{items:[{metadata:{name:"cilium-a"},spec:{nodeName:"n1"},status:{phase:"Running"}},
                          {metadata:{name:"cilium-b"},spec:{nodeName:"n2"},status:{phase:"Running"}}]}')"

# One run. Fixture files: $WORK/pods, $WORK/eps (or eps.fail), and per pod
# $WORK/svc.<pod>.<read#> (falls back to $WORK/svc.<pod>), or svc.<pod>.fail.
run() {
  (
    SUMMARY=(); DETAILS=(); FAIL_COUNT=0; WARN_COUNT=0; SKIP_COUNT=0
    record() {
      local level="$1" name="$2" msg="${3:-}"
      case "$level" in
        ok)   SUMMARY+=("OK|${name}|${msg}") ;;
        warn) SUMMARY+=("WARN|${name}|${msg}"); ((WARN_COUNT++)) ;;
        fail) SUMMARY+=("FAIL|${name}|${msg}"); ((FAIL_COUNT++)) ;;
        skip) SUMMARY+=("SKIP|${name}|${msg}"); ((SKIP_COUNT++)) ;;
      esac
    }
    sleep() { :; }
    kubectl() {
      local a="$*"
      case "$a" in
        "-n kube-system get pods -l k8s-app=cilium -o json")
          [[ -f "$WORK/pods" ]] && cat "$WORK/pods" || return 1 ;;
        "get endpointslices -A -o json")
          [[ -f "$WORK/eps.fail" ]] && return 1; cat "$WORK/eps" ;;
        "-n kube-system exec "*" -c cilium-agent -- cilium-dbg service list -o json")
          local pod n f; pod=$(awk '{print $4}' <<<"$a")
          [[ -f "$WORK/svc.$pod.fail" ]] && return 1
          n=$(( $(cat "$WORK/reads.$pod" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/reads.$pod"
          f="$WORK/svc.$pod.$n"; [[ -f "$f" ]] || f="$WORK/svc.$pod"
          cat "$f" ;;
        *) echo "UNEXPECTED kubectl $a" >> "$WORK/unexpected"; return 99 ;;
      esac
    }
    eval "$BLOCK"
    printf '%s\n' "${SUMMARY[@]}"
  ) 2>/dev/null
}
reset() { rm -f "$WORK"/svc.* "$WORK"/reads.* "$WORK"/eps* "$WORK"/pods; printf '%s' "$PODS2" > "$WORK/pods"; printf '%s' "$EPS_OK" > "$WORK/eps"; }
lvl() { cut -d'|' -f1 <<<"$1" | head -1; }
n_rows() { grep -c '|Cilium backends vs EndpointSlice|' <<<"$1"; }
case_() {  # name expected-level output [grep-pattern...]
  local name="$1" want="$2" out="$3"; shift 3
  [[ "$(n_rows "$out")" == 1 ]] || { fail "$name: expected exactly one row-27 line, got $(n_rows "$out"): $(tr '\n' ' ' <<<"$out")"; return; }
  [[ "$(lvl "$out")" == "$want" ]] || { fail "$name: expected $want, got $(lvl "$out"): $(tr '\n' ' ' <<<"$out")"; return; }
  local p; for p in "$@"; do grep -qF -- "$p" <<<"$out" || fail "$name: the $want line does not say '$p': $(tr '\n' ' ' <<<"$out")"; done
}

# 0. both agents agree → ok, and the ok line carries what it compared.
reset; for p in cilium-a cilium-b; do printf '%s' "$DNS_OK" | list > "$WORK/svc.$p"; done
case_ "agree" OK "$(run)" "2 node(s)" "n1 1" "n2 1"

# 1. the measured defect: n1's agent holds a backend the API does not.
reset; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-b"
svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53 10.0.14.1:53 | list > "$WORK/svc.cilium-a"
case_ "stale backend" FAIL "$(run)" "n1" "10.0.14.1:53" "kube-system/kube-dns"
[[ "$(cat "$WORK/reads.cilium-a")" == 2 ]] || fail "stale backend: the drift was reported without the second read (reads=$(cat "$WORK/reads.cilium-a"))"

# 2. transient: the first read differs, the second agrees → not reported.
reset; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-b"; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-a.2"
svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53 10.0.14.1:53 | list > "$WORK/svc.cilium-a.1"
case_ "transient" OK "$(run)"

# 2b. two reads that each differ, but on DIFFERENT services (two rollouts in
#     flight) → nothing held across both, so not reported.
reset; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-b"
printf '%s' "$( { eps kube-dns kube-system 53 10.0.0.62:n1:true 10.0.2.162:n2:true; eps web ns1 80 10.0.5.5:n1:true; } | items)" > "$WORK/eps"
{ svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53 10.0.14.1:53; svc web ns1 Cluster 10.0.5.5:80; } | list > "$WORK/svc.cilium-a.1"
{ svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53; svc web ns1 Cluster 10.0.5.5:80 10.0.6.6:80; } | list > "$WORK/svc.cilium-a.2"
{ svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53; svc web ns1 Cluster 10.0.5.5:80; } | list > "$WORK/svc.cilium-b"
case_ "different services each read" OK "$(run)"

# 3. an agent only LACKS a ready backend → warn, not fail.
reset; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-b"
svc kube-dns kube-system Cluster 10.0.0.62:53 | list > "$WORK/svc.cilium-a"
case_ "missing only" WARN "$(run)" "n1" "10.0.2.162:53"

# 4. one agent cannot be exec'd → skip naming it; the other node's ok is not enough.
reset; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-b"; : > "$WORK/svc.cilium-a.fail"
case_ "exec refused" SKIP "$(run)" "n1" "exec into cilium-a failed"

# 5. red outranks not-measured: n2 stale, n1 refused → fail that also names n1.
reset; : > "$WORK/svc.cilium-a.fail"
svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53 10.0.14.1:53 | list > "$WORK/svc.cilium-b"
case_ "fail over skip" FAIL "$(run)" "10.0.14.1:53" "not measured: n1"

# 6. no agents listed → skip.
reset; rm -f "$WORK/pods"
case_ "no agents" SKIP "$(run)" "no running Cilium agent"

# 7. agent output is not a JSON list → skip with that reason.
reset; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-b"; printf 'Error: unknown flag -o\n' > "$WORK/svc.cilium-a"
case_ "not json" SKIP "$(run)" "not a JSON list"

# 8. EndpointSlices unreadable → skip with that reason.
reset; for p in cilium-a cilium-b; do printf '%s' "$DNS_OK" | list > "$WORK/svc.$p"; done; : > "$WORK/eps.fail"
case_ "eps unreadable" SKIP "$(run)" "EndpointSlices"

# 9. nothing in common to compare → skip, never ok.
reset; for p in cilium-a cilium-b; do svc other ns1 Cluster 10.9.0.1:80 | list > "$WORK/svc.$p"; done
case_ "nothing compared" SKIP "$(run)" "nothing was compared"

# 10. internalTrafficPolicy Local: the agent lists only its node's endpoints.
reset
svc kube-dns kube-system Local 10.0.0.62:53 | list > "$WORK/svc.cilium-a"
svc kube-dns kube-system Local 10.0.2.162:53 | list > "$WORK/svc.cilium-b"
case_ "local policy" OK "$(run)"

# 11. a terminating backend in the agent and a not-ready endpoint in the API are not drift.
reset; printf '%s' "$DNS_OK" | list > "$WORK/svc.cilium-b"
svc kube-dns kube-system Cluster 10.0.0.62:53 10.0.2.162:53 10.0.7.7:53:terminating | list > "$WORK/svc.cilium-a"
eps kube-dns kube-system 53 10.0.0.62:n1:true 10.0.2.162:n2:true 10.0.8.8:n2:false | items > "$WORK/eps"
case_ "terminating / not ready" OK "$(run)"

[[ -s "$WORK/unexpected" ]] && fail "the row made kubectl calls the stub does not model: $(sort -u "$WORK/unexpected" | tr '\n' ';')"

if [[ $rc -eq 0 ]]; then
  echo "PASS — row 27: agree → ok; stale backend held over two reads → fail (named); transient → ok; missing only → warn; exec refused / no agents / not JSON / EndpointSlices unreadable / nothing compared → skip with distinct reasons; fail outranks skip; drift on different services in the two reads is not held; Local policy, terminating and not-ready are not drift (13 cases)"
fi
exit $rc
