#!/usr/bin/env bash
# Assert daily-check row 29 (Envoy proxies connected to xDS, ferry133/jg-base#199)
# gives every verdict it claims, from the real block in the ConfigMap.
#
# Stubs answer ONLY what the row asks: `kubectl get pods -A -l
# app.kubernetes.io/managed-by=envoy-gateway -o json`, `curl` to
# http://<ip>:<port>/stats/prometheus (keyed by ip:port, with a per-read
# sequence so a proxy can read 0 and then 1), and `sleep`. Anything else fails
# loudly: a stub that ignores its arguments is a constant, and a row reading
# the wrong port or path would pass.
#
# Usage: scripts/check-envoy-xds-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cannot measure: jq is missing"; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/envoy-xds-row.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

BLOCK="$(awk '
    /^[[:space:]]*# 29\. Envoy proxies connected to xDS/ { grabbing = 1 }
    grabbing && /^[[:space:]]*# [0-9]+[a-z]?\. / && !/# 29\./ { exit }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: row 29 was not found in the ConfigMap"; exit 2; }
grep -q 'managed-by=envoy-gateway' <<<"$BLOCK" || { echo "cannot measure: extracted block is not row 29"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

pod() {  # ns/name ip phase port(- for none)
  local ns="${1%%/*}" name="${1#*/}" ports='[]'
  [[ "$4" != "-" ]] && ports="[{\"name\":\"admin\",\"containerPort\":19000},{\"name\":\"metrics\",\"containerPort\":$4}]"
  printf '{"metadata":{"namespace":"%s","name":"%s"},"spec":{"containers":[{"name":"envoy","ports":%s},{"name":"shutdown-manager"}]},"status":{"phase":"%s","podIP":"%s"}}' \
    "$ns" "$name" "$ports" "$3" "$2"
}
# metrics body for a gauge value; "none" = a body without the gauge, "bare" = the
# unlabelled spelling with value 1
body() {
  case "$1" in
    none) printf '# TYPE envoy_server_live gauge\nenvoy_server_live{} 1\n' ;;
    bare) printf 'envoy_control_plane_connected_state 1\n' ;;
    # The `_total` sibling comes FIRST, so a prefix match would read its 7.
    *)    printf 'envoy_control_plane_connected_state_total{} 7\n# TYPE envoy_control_plane_connected_state gauge\nenvoy_control_plane_connected_state{} %s\n' "$1" ;;
  esac
}

# case name | pod items | per-endpoint reads ("ip:port=v1,v2 ..."; v = 0|1|none|bare|down|<other>)
#   | refuse pods (yes|no) | want level | want texts (" && "-separated; each must appear) | want sleeps
run_case() {
  local name="$1" items="$2" reads="$3" refuse="$4" want="$5" texts="$6" sleeps="$7"
  rm -rf "$WORK/c"; mkdir -p "$WORK/c"
  printf '{"items":[%s]}' "$items" > "$WORK/c/pods.json"
  local r ep vals
  for r in $reads; do ep="${r%%=*}"; vals="${r#*=}"; tr ',' '\n' <<<"$vals" > "$WORK/c/$ep"; done
  out="$(REFUSE="$refuse" W="$WORK/c" bash -c '
    set -uo pipefail
    record() { echo "$1|$2|${3:-}"; }
    kubectl() {
      case "$*" in
        "get pods -A -l app.kubernetes.io/managed-by=envoy-gateway -o json") [[ "$REFUSE" == yes ]] && return 1; cat "$W/pods.json" ;;
        *) echo "STUB: unexpected kubectl $*" >&2; return 99 ;;
      esac
    }
    curl() {
      local url="${*: -1}"
      [[ "$url" =~ ^http://([0-9.]+:[0-9]+)/stats/prometheus$ ]] || { echo "STUB: unexpected curl $*" >&2; return 99; }
      local ep="${BASH_REMATCH[1]}" n v
      [[ -f "$W/$ep" ]] || { echo "STUB: curl to an endpoint with no fixture: $ep" >&2; return 99; }
      n=$(( $(cat "$W/$ep.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$W/$ep.n"
      v=$(sed -n "${n}p" "$W/$ep"); [[ -n "$v" ]] || v=$(tail -1 "$W/$ep")
      [[ "$v" == down ]] && return 7
      '"$(declare -f body)"'
      body "$v"
    }
    sleep() { echo "slept" >> "$W/sleeps"; }
    '"$BLOCK"'
  ' 2>&1)"
  if grep -q '^STUB:' <<<"$out"; then fail "$name: the row asked something unexpected: $(grep '^STUB:' <<<"$out" | head -1)"; return; fi
  local lines; lines="$(grep -c '|Envoy xDS connection|' <<<"$out")"
  if [[ "$lines" -ne 1 ]]; then fail "$name: expected exactly one record, got $lines: $out"; return; fi
  local got; got="$(grep '|Envoy xDS connection|' <<<"$out")"
  local msg="${got#*|Envoy xDS connection|}" rest="$texts" t missing=""
  while [[ -n "$rest" ]]; do
    t="${rest%% && *}"
    if [[ "$rest" == *" && "* ]]; then rest="${rest#* && }"; else rest=""; fi
    grep -qF -- "$t" <<<"$msg" || missing="${missing} \"$t\""
  done
  local slept=0
  [[ -f "$WORK/c/sleeps" ]] && slept=$(wc -l < "$WORK/c/sleeps")
  slept=$((slept + 0))
  if [[ "${got%%|*}" != "$want" || -n "$missing" ]]; then
    fail "$name: wanted $want with$missing, got: $got"
  elif [[ "$slept" -ne "$sleeps" ]]; then
    fail "$name: wanted $sleeps sleep(s) before the verdict, the row slept $slept"
  else
    echo "PASS  $name  ->  ${got%%|*} (slept $slept): $msg"
  fi
}

A="$(pod network/envoy-internal-a 10.0.0.1 Running 19001)"
B="$(pod mqtt/tcp-gateway-b 10.0.0.2 Running 19001)"

run_case "0 no proxies" "" "" no skip "no running Envoy Gateway proxy pods" 0
run_case "1 pods unreadable" "" "" yes skip "could not be listed" 0
run_case "2 all connected" "$A,$B" "10.0.0.1:19001=1 10.0.0.2:19001=1" no ok "2 proxy pod(s) connected" 0
run_case "3 one held at 0 (the #193 state)" "$A,$B" "10.0.0.1:19001=0,0 10.0.0.2:19001=1" no fail "disconnected && network/envoy-internal-a" 1
run_case "4 0 then 1 is a reconnect, not an outage" "$A,$B" "10.0.0.1:19001=0,1 10.0.0.2:19001=1" no ok "2 proxy pod(s) connected" 1
run_case "5 metrics port unreachable" "$A,$B" "10.0.0.1:19001=down 10.0.0.2:19001=1" no skip "1 connected && network/envoy-internal-a: metrics port 19001 did not answer" 0
run_case "6 gauge absent" "$A" "10.0.0.1:19001=none" no skip "no envoy_control_plane_connected_state" 0
run_case "7 red outranks not-measured" "$A,$B" "10.0.0.1:19001=0,0 10.0.0.2:19001=down" no fail "network/envoy-internal-a && not measured: mqtt/tcp-gateway-b" 1
run_case "8 no metrics port declared" "$(pod network/envoy-x 10.0.0.3 Running -)" "" no skip "declares no container port named metrics" 0
run_case "9 non-Running pod ignored" "$A,$(pod network/envoy-old 10.0.0.9 Pending 19001)" "10.0.0.1:19001=1" no ok "1 proxy pod(s) connected" 0
run_case "10 port comes from the spec, not a constant" "$(pod omni/udp-gateway-c 10.0.0.4 Running 19555)" "10.0.0.4:19555=1" no ok "1 proxy pod(s) connected" 0
run_case "11 unlabelled gauge spelling" "$A" "10.0.0.1:19001=bare" no ok "1 proxy pod(s) connected" 0
run_case "12 a value that is neither 0 nor 1" "$A" "10.0.0.1:19001=2" no skip "neither 0 nor 1" 0
run_case "13 _total sibling is not the gauge" "$A" "10.0.0.1:19001=0,0" no fail "network/envoy-internal-a" 1
run_case "14 0 then unreachable is not ok" "$A" "10.0.0.1:19001=0,down" no skip "read 0, then metrics port 19001 did not answer" 1
run_case "15 two down, one sleep" "$A,$B" "10.0.0.1:19001=0,0 10.0.0.2:19001=0,0" no fail "network/envoy-internal-a mqtt/tcp-gateway-b" 1

[[ $rc -eq 0 ]] && echo "ok — row 29 gives skip/ok/fail as specified across 16 cases, sleeping only before a re-read"
exit $rc
