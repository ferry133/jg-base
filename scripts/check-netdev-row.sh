#!/usr/bin/env bash
# Assert daily-check row 31 (netdev-mcp sidecar, ferry133/jg-base#222) gives
# every verdict it claims, from the real block in the ConfigMap.
#
# The kubectl stub answers ONLY what the row asks: im's Deployment, its pods by
# the Deployment's own selector, one container's log, and the baseline
# ConfigMap's get and patch. Anything else fails loudly — a stub that ignores
# its arguments is a constant. The patch is recorded, so "the baseline moved
# to X" and "the baseline was not touched" are both asserted.
#
# The log lines are k8scc's own strings (netdev_mcp_server.py
# `_startup_readings` and `_audit`, k8scc f5861a2), not paraphrases. Timestamps
# are made relative to now, so the 24 h window is exercised both ways.
#
# ⚠️ Runs the row under GNU date (gdate on macOS). The CronJob runs busybox;
# `date -u -d @epoch` is the spelling both accept, and `epoch_of` is the row
# file's own helper, extracted below, not a copy.
#
# Usage: scripts/check-netdev-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="$ROOT/kubernetes/apps/base/monitoring/daily-check"
CM="$DC/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: daily-check ConfigMap not readable"; exit 2; }
for t in jq python3; do command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }; done
if date --version >/dev/null 2>&1; then GNUDATE=date
elif command -v gdate >/dev/null 2>&1; then GNUDATE=gdate
else echo "cannot measure: no GNU date (date or gdate)"; exit 2; fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/netdev-row.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

BLOCK="$(awk '
    /^[[:space:]]*# 31\. netdev-mcp sidecar/ { grabbing = 1 }
    grabbing && /^[[:space:]]*# [0-9]+[a-z]?\. / && !/# 31\./ { exit }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: row 31 was not found in the ConfigMap"; exit 2; }
grep -q 'ND_NAME="netdev-mcp sidecar"' <<<"$BLOCK" || { echo "cannot measure: extracted block is not row 31"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }
EPOCH_OF="$(awk '/^    epoch_of\(\) \{/ { g = 1 } g { print } g && /^    \}/ { exit }' "$CM" | sed 's/^    //')"
grep -q 'date -u -D' <<<"$EPOCH_OF" || { echo "cannot measure: epoch_of was not found in the ConfigMap"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# The grants the row needs, applied where it needs them.
grep -q 'resources: \["pods/log"\]' "$DC/claudecode/rbac.yaml" 2>/dev/null \
  && grep -q '^  namespace: claudecode$' "$DC/claudecode/rbac.yaml" \
  || fail "claudecode/rbac.yaml does not grant pods/log in claudecode — the row would always skip"
grep -q 'path: ./kubernetes/apps/base/monitoring/daily-check/claudecode' "$DC/ks.yaml" \
  || fail "no Flux Kustomization applies daily-check/claudecode — the Role would never exist"
awk '/name: daily-check-netdev-logs/ { k = 1 } k && /targetNamespace/ { bad = 1 } k && /^---/ { k = 0 } END { exit bad }' "$DC/ks.yaml" \
  || fail "daily-check-netdev-logs sets targetNamespace — the Role would land outside claudecode (#173)"
python3 - "$DC/app/rbac.yaml" <<'PY' || fail "rbac.yaml does not grant exactly get+patch on configmaps/daily-check-state"
import sys, re
docs = open(sys.argv[1]).read().split("\n---")
role = [d for d in docs if re.search(r"^kind: Role$", d, re.M) and "name: daily-check-state" in d]
ok = len(role) == 1 and 'resourceNames: ["daily-check-state"]' in role[0] and 'verbs: ["get", "patch"]' in role[0]
sys.exit(0 if ok else 1)
PY
grep -q 'kustomize.toolkit.fluxcd.io/ssa: IfNotPresent' "$DC/app/state.yaml" 2>/dev/null \
  || fail "state.yaml is not ssa: IfNotPresent — every reconcile would wipe the baseline"

iso() { python3 -c 'import sys,datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).isoformat(timespec="seconds"))' "$1"; }
isoz() { iso "$1" | sed 's/+00:00$/Z/'; }   # Kubernetes writes startedAt with Z

DEPLOY_ND='{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"im"}},"template":{"spec":{"containers":[{"name":"app"},{"name":"talos-mcp"},{"name":"netdev-mcp"}]}}}}'
DEPLOY_PLAIN='{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"im"}},"template":{"spec":{"containers":[{"name":"app"},{"name":"talos-mcp"}]}}}}'
pod() {  # name startedAt(or "-" = not running)
  if [[ "$2" == "-" ]]; then
    printf '{"metadata":{"name":"%s"},"status":{"containerStatuses":[{"name":"app","state":{"running":{}}},{"name":"netdev-mcp","state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}' "$1"
  else
    printf '{"metadata":{"name":"%s"},"status":{"containerStatuses":[{"name":"app","state":{"running":{"startedAt":"%s"}}},{"name":"netdev-mcp","state":{"running":{"startedAt":"%s"}}}]}}' "$1" "$2" "$2"
  fi
}
startup() {  # reader version operator writes
  printf '%s\n' "netdev-mcp: controller: 192.0.2.1, site default" "netdev-mcp: reader credential: $1" \
    "netdev-mcp: operator credential: $3" "netdev-mcp: ticket channel: fixture/im-fac via api.github.com" \
    "netdev-mcp: outside probes: https://api.github.com/zen, minio.example.test:443, 1.1.1.1:53" \
    "netdev-mcp: POD_IP: 192.0.2.10" "netdev-mcp: snapshot dir: /var/lib/netdev-mcp/snapshots (keep 50)" \
    "netdev-mcp: write tools: $4"
  [[ "$2" == "-" ]] || echo "netdev-mcp: controller version: $2"
  echo 'INFO:     Uvicorn running on http://127.0.0.1:8766 (Press CTRL+C to quit)'
}
audit() {  # seconds-ago phase [fac_witness]
  printf '{"ts": "%s", "tool": "set_dhcp_reservation", "target": "users/aa:bb:cc:00:00:01", "phase": "%s", "stated_reason": "x", "user": "", "snapshot_digest": "", "diff_digest": "", "health": [], "outbound": "", "fac_witness": "%s"}\n' "$(iso "$1")" "$2" "${3:-}"
}
# The real strings, k8scc f5861a2 (WRITE_TOOLS, _write_blockers) — not invented names, which
# read like a recorded output (k8scc-c7 on #238; the first version had two invented ones).
REG="registered — set_dhcp_reservation, clear_dhcp_reservation, block_client, unblock_client, set_port_forward, delete_port_forward, restart_device, power_cycle_port; set_dns_forward not shipped (root spike 1.1)"
NOTREG="not registered — operator credential absent (UNIFI_OPERATOR_FILE unset)"
WEEK="$(isoz 604800)"
# Computed once and shared by input and expectation: two calls can straddle a
# second (the first run of this guard did, and case 18 read red).
TWOH="$(isoz 7200)"; ONEH="$(isoz 3600)"

# case | deploy | pods json (- = refuse) | log file | log mode (ok|forbidden|error) | state (- = unreadable, "" = no key, else the baseline) | patch (ok|refuse) | want level | want patched (- = untouched) | texts (" && ")
run_case() {
  local name="$1" deploy="$2" pods="$3" log="$4" logmode="$5" state="$6" patch="$7" want="$8" wantpatch="$9" texts="${10}"
  rm -rf "$WORK/c"; mkdir -p "$WORK/c"
  printf '%s' "$deploy" > "$WORK/c/deploy.json"; printf '%s' "$pods" > "$WORK/c/pods.json"; printf '%s' "$log" > "$WORK/c/log"
  out="$(W="$WORK/c" LOGMODE="$logmode" STATE="$state" PATCH="$patch" GNUDATE="$GNUDATE" bash -c '
    set -uo pipefail
    record() { echo "$1|$2|${3:-}"; }
    date() { "$GNUDATE" "$@"; }
    '"$EPOCH_OF"'
    kubectl() {
      case "$*" in
        "-n claudecode get deploy im -o json") [[ -s "$W/deploy.json" ]] || return 1; cat "$W/deploy.json" ;;
        "-n claudecode get pods -l app.kubernetes.io/name=im -o json") [[ "$(cat "$W/pods.json")" == "-" ]] && return 1; cat "$W/pods.json" ;;
        "-n claudecode logs im-new -c netdev-mcp")
          case "$LOGMODE" in
            ok) cat "$W/log" ;;
            forbidden) echo "Error from server (Forbidden): pods \"im-new\" is forbidden: User \"system:serviceaccount:monitoring:daily-check\" cannot get resource \"pods/log\""; return 1 ;;
            error) echo "Error from server (BadRequest): container \"netdev-mcp\" in pod \"im-new\" is waiting to start"; return 1 ;;
          esac ;;
        "-n monitoring get configmap daily-check-state -o json")
          [[ "$STATE" == "-" ]] && return 1
          if [[ -z "$STATE" ]]; then echo "{\"metadata\":{\"name\":\"daily-check-state\"}}"
          else jq -nc --arg v "$STATE" "{metadata:{name:\"daily-check-state\"},data:{\"netdev-controller-version\":\$v}}"; fi ;;
        "-n monitoring patch configmap daily-check-state --type=merge --field-manager=daily-check -p "*)
          [[ "$PATCH" == refuse ]] && return 1
          echo "$9" | jq -er ".data[\"netdev-controller-version\"]" > "$W/patched" || { echo "STUB: bad patch body $9" >&2; return 99; } ;;
        *) echo "STUB: unexpected kubectl $*" >&2; return 99 ;;
      esac
    }
    '"$BLOCK"'
  ' 2>&1)"
  if grep -q 'STUB:' <<<"$out"; then fail "$name: the row asked something unexpected: $(grep 'STUB:' <<<"$out" | head -1)"; return; fi
  local lines; lines="$(grep -c '|netdev-mcp sidecar|' <<<"$out")"
  if [[ "$lines" -ne 1 ]]; then fail "$name: expected exactly one record, got $lines: $out"; return; fi
  local got; got="$(grep '|netdev-mcp sidecar|' <<<"$out")"
  local msg; msg="$(sed 's/^[a-z]*|netdev-mcp sidecar|//' <<<"$got")"
  local rest="$texts" t missing="" patched="-"
  [[ -f "$WORK/c/patched" ]] && patched="$(cat "$WORK/c/patched")"
  while [[ -n "$rest" ]]; do
    t="$(sed 's/ && .*//' <<<"$rest")"
    if [[ "$rest" == *" && "* ]]; then rest="$(sed 's/^[^&]* && //' <<<"$rest")"; else rest=""; fi
    grep -qF -- "$t" <<<"$msg" || missing="${missing} \"$t\""
  done
  local level; level="$(cut -d'|' -f1 <<<"$got")"
  if [[ "$level" != "$want" || -n "$missing" || "$patched" != "$wantpatch" ]]; then
    fail "$name: wanted $want, baseline -> $wantpatch, with$missing; got: $got (baseline -> $patched)"
  else
    echo "PASS  $name  ->  $level: $(cut -c1-150 <<<"$msg")"
  fi
}

ONE="{\"items\":[$(pod im-new "$WEEK")]}"
STEADY="$(startup ok 9.0.114 ok "$REG"; audit 90000 revert-failed; audit 7200 token unmeasured; audit 7100 execute; audit 3600 token armed)"
run_case "0 steady: unchanged, old revert-failed outside the window" "$DEPLOY_ND" "$ONE" "$STEADY" ok 9.0.114 ok ok - \
  "controller 9.0.114 (unchanged && operator ok && write tools registered && audit last 24 h: execute 1, token 2 && fac_witness unmeasured on 1/2 token(s)"
run_case "1 no im" "" "$ONE" "" ok 9.0.114 ok skip - "no im deployment"
run_case "2 no netdev-mcp container" "$DEPLOY_PLAIN" "$ONE" "" ok 9.0.114 ok skip - "no UniFi console recorded"
run_case "3 pods unlistable" "$DEPLOY_ND" "-" "" ok 9.0.114 ok skip - "im pods could not be listed"
run_case "4 declared, not running" "$DEPLOY_ND" "{\"items\":[$(pod im-new -)]}" "" ok 9.0.114 ok fail - "none is running"
run_case "5 logs forbidden" "$DEPLOY_ND" "$ONE" "" forbidden 9.0.114 ok skip - "no RBAC permission to read pods/log && not the same as clean"
run_case "6 logs otherwise unreadable" "$DEPLOY_ND" "$ONE" "" error 9.0.114 ok skip - "unreadable: Error from server (BadRequest)"
run_case "7 startup readings rotated away" "$DEPLOY_ND" "$ONE" "$(audit 60 token armed)" ok 9.0.114 ok skip - "no longer in the log (rotated) && not measured"
run_case "8 reader credential missing" "$DEPLOY_ND" "$ONE" "$(startup 'missing reader API key (UNIFI_READER_KEY_FILE=/etc/netdev-mcp/reader/reader-key)' - "not tried (the reader is not usable)" "not registered — reader not usable")" ok 9.0.114 ok fail - "reader credential missing reader API key"
run_case "9 controller unreadable" "$DEPLOY_ND" "$ONE" "$(startup ok 'unreadable (error: GET /api/s/default/stat/sysinfo: timed out)' ok "$REG")" ok 9.0.114 ok fail - "controller version unreadable (error: GET && cannot reach the controller"
run_case "10 no version line at all" "$DEPLOY_ND" "$ONE" "$(startup ok - ok "$REG")" ok 9.0.114 ok fail - "never reached the controller"
run_case "11 revert-failed in the window" "$DEPLOY_ND" "$ONE" "$(startup ok 9.0.114 ok "$REG"; audit 600 token armed; audit 500 revert-failed armed)" ok 9.0.114 ok fail - "1 revert-failed write(s) && revert-failed 1"
run_case "12 version changed: warn once, baseline moves" "$DEPLOY_ND" "$ONE" "$(startup ok 9.1.120 ok "$REG")" ok 9.0.114 ok warn 9.1.120 "controller version changed: 9.0.114 → 9.1.120 && warns once"
run_case "13 first reading: ok, baseline recorded" "$DEPLOY_ND" "$ONE" "$(startup ok 9.0.114 ok "$REG")" ok "" ok ok 9.0.114 "first reading, recorded as baseline"
run_case "14 operator absent: reader-only is ok" "$DEPLOY_ND" "$ONE" "$(startup ok 9.0.114 'absent (UNIFI_OPERATOR_FILE unset)' "$NOTREG")" ok 9.0.114 ok ok - "operator absent (UNIFI_OPERATOR_FILE unset) && write tools not registered && no write phases"
run_case "14b operator invalid: warn, not reader-only" "$DEPLOY_ND" "$ONE" "$(startup ok 9.0.114 'invalid (login refused: 401)' "not registered — operator credential invalid (login refused: 401)")" ok 9.0.114 ok warn - "operator credential invalid (login refused: 401) — mounted but unusable"
run_case "14c operator empty, first reading: warn, baseline still recorded" "$DEPLOY_ND" "$ONE" "$(startup ok 9.0.114 'empty (/etc/netdev-mcp/operator/operator)' "not registered — operator credential empty (/etc/netdev-mcp/operator/operator)")" ok "" ok warn 9.0.114 "operator credential empty && first reading, recorded as baseline"
run_case "15 version not reported" "$DEPLOY_ND" "$ONE" "$(startup ok 'not reported' ok "$REG")" ok 9.0.114 ok warn - "answered without a version && change not judged"
run_case "16 baseline unreadable" "$DEPLOY_ND" "$ONE" "$(startup ok 9.1.120 ok "$REG")" ok - ok warn - "baseline ConfigMap monitoring/daily-check-state is unreadable && not judged"
run_case "17 baseline unwritable" "$DEPLOY_ND" "$ONE" "$(startup ok 9.1.120 ok "$REG")" ok 9.0.114 refuse warn - "could not be written && judged again tomorrow"
run_case "18 young container: window says so" "$DEPLOY_ND" "{\"items\":[$(pod im-new "$TWOH")]}" "$(startup ok 9.0.114 ok "$REG"; audit 60 token armed)" ok 9.0.114 ok ok - "audit since $TWOH only (earlier containers' lines are gone)"
run_case "19 red outranks: revert-failed and a new version" "$DEPLOY_ND" "$ONE" "$(startup ok 9.1.120 ok "$REG"; audit 500 revert-failed)" ok 9.0.114 ok fail - "revert-failed write(s)"
# The older pod is listed FIRST: listed newest-first, "take the first" passed
# this case too (mutation d survived the first version).
run_case "20 newest running pod is read" "$DEPLOY_ND" "{\"items\":[$(pod im-old "$WEEK"),$(pod im-new "$ONEH")]}" "$(startup ok 9.0.114 ok "$REG")" ok 9.0.114 ok ok - "read at sidecar start $ONEH"

[[ $rc -eq 0 ]] && echo "ok — row 31 gives skip/ok/warn/fail as specified across 23 cases (k8scc f5861a2 strings), the baseline moves only on a judged change, and the pods/log and baseline grants are where the row needs them"
exit $rc
