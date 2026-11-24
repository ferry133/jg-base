#!/usr/bin/env bash
# Assert daily-check row 33 (im chamber, ferry133/jg-base#248) gives every
# verdict it claims, from the real block in the ConfigMap.
#
# The kubectl stub answers ONLY what the row asks: im's Deployment, its pods by
# the Deployment's own selector, and three log reads (the bridge's tail, app's
# tail, app's whole log). Anything else fails loudly: a stub that ignores its
# arguments is a constant.
#
# Cases 34-39 are the intermittent link (fleet-ops-02 on #267): the newest
# line is not judged alone, and a server is down only when every fresh line
# says so.
#
# The status lines follow k8scc's committed format (v1, jg-base#248 comment
# 7130894158). Three of the fixtures are lines read live on 2026-11-24 with
# only `ts` replaced: jg-jcc2 (deliver, online), jcom (observe) and jg-jiahd
# (observe, rooms=unmeasured). `ts` is made relative to now, so the "too old"
# limit is exercised on both sides.
#
# Usage: scripts/check-chamber-row.sh [--self-test]
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
#   --self-test also mutates the row and expects the cases to notice.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="$ROOT/kubernetes/apps/base/monitoring/daily-check"
CM="${CHAMBER_ROW_CM:-$DC/app/configmap.yaml}"
[[ -r "$CM" ]] || { echo "cannot measure: daily-check ConfigMap not readable"; exit 2; }
for t in jq awk sed; do command -v "$t" >/dev/null 2>&1 || { echo "cannot measure: $t is missing"; exit 2; }; done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/chamber-row.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

BLOCK="$(awk '
    /^[[:space:]]*# 33\. im chamber/ { grabbing = 1 }
    grabbing && /^[[:space:]]*# [0-9]+[a-z]?\. / && !/# 33\./ { exit }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: row 33 was not found in the ConfigMap"; exit 2; }
grep -q 'CH_NAME="im chamber"' <<<"$BLOCK" || { echo "cannot measure: extracted block is not row 33"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# The grant the row needs is row 31's; it must still be where the row reads.
if [[ -z "${CHAMBER_ROW_CM:-}" ]]; then
  grep -q 'resources: \["pods/log"\]' "$DC/claudecode/rbac.yaml" 2>/dev/null \
    && grep -q '^  namespace: claudecode$' "$DC/claudecode/rbac.yaml" \
    || fail "claudecode/rbac.yaml does not grant pods/log in claudecode — the row would always skip"
fi

NOW="$(date -u +%s)"
DEPLOY_CH='{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"im"}},"template":{"spec":{"containers":[{"name":"app"},{"name":"talos-mcp"},{"name":"chamber-bridge"}]}}}}'
DEPLOY_PLAIN='{"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"im"}},"template":{"spec":{"containers":[{"name":"app"},{"name":"talos-mcp"}]}}}}'
pod() {  # name startedAt(or "-" = bridge not running)
  if [[ "$2" == "-" ]]; then
    printf '{"metadata":{"name":"%s"},"status":{"containerStatuses":[{"name":"app","state":{"running":{}}},{"name":"chamber-bridge","state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}' "$1"
  else
    printf '{"metadata":{"name":"%s"},"status":{"containerStatuses":[{"name":"app","state":{"running":{"startedAt":"%s"}}},{"name":"chamber-bridge","state":{"running":{"startedAt":"%s"}}}]}}' "$1" "$2" "$2"
  fi
}
ONE="{\"items\":[$(pod im-new 2026-11-24T09:37:50Z)]}"
st() {  # age-seconds mode server rooms online [interval]
  echo "chamber-bridge: started — mode=$2 account=im-fixture socket=/run/chamber/bridge.sock — the credential is in this container only"
  echo "chamber-status ts=$(( NOW - 4000 )) interval=${6:-20} mode=deliver server=unreachable rooms=unmeasured online=unmeasured"
  echo "chamber-status ts=$(( NOW - $1 )) interval=${6:-20} mode=$2 server=$3 rooms=$4 online=$5"
}
ln() {  # one status line: age-seconds mode server rooms online
  echo "chamber-status ts=$(( NOW - $1 )) interval=20 mode=$2 server=$3 rooms=$4 online=$5"
}
vf() {  # age-seconds signers revoked sshkeygen
  echo "entrypoint: starting"
  echo "inbox-watch: watching /home/claude/inbox"
  echo "chamber-verify-status ts=$(( NOW - 5000 )) interval=20 signers=0 revoked=0 sshkeygen=missing"
  echo "chamber-verify-status ts=$(( NOW - $1 )) interval=20 signers=$2 revoked=$3 sshkeygen=$4"
  echo "session-keep: alive"
}
GOODV="$(vf 12 1 0 ok)"

# name | deploy | pods (- = refuse) | bridge log | bridge mode (ok|forbidden|error) | app tail | app mode (ok|error) | app whole log | want | texts (" && ") | absent texts (" && ")
run_case() {
  local name="$1" deploy="$2" pods="$3" blog="$4" bmode="$5" atail="$6" amode="$7" afull="$8" want="$9" texts="${10}" nots="${11:-}"
  rm -rf "$WORK/c"; mkdir -p "$WORK/c"
  printf '%s' "$deploy" > "$WORK/c/deploy.json"; printf '%s' "$pods" > "$WORK/c/pods.json"
  printf '%s\n' "$blog" > "$WORK/c/blog"; printf '%s\n' "$atail" > "$WORK/c/atail"; printf '%s\n' "$afull" > "$WORK/c/afull"
  out="$(W="$WORK/c" BMODE="$bmode" AMODE="$amode" CLUSTER_NAME=jg-fixture bash -c '
    set -uo pipefail
    record() { echo "$1|$2|${3:-}"; }
    kubectl() {
      case "$*" in
        "-n claudecode get deploy im -o json") [[ -s "$W/deploy.json" ]] || return 1; cat "$W/deploy.json" ;;
        "-n claudecode get pods -l app.kubernetes.io/name=im -o json") [[ "$(cat "$W/pods.json")" == "-" ]] && return 1; cat "$W/pods.json" ;;
        "-n claudecode logs im-new -c chamber-bridge --tail=200")
          case "$BMODE" in
            ok) cat "$W/blog" ;;
            forbidden) echo "Error from server (Forbidden): pods \"im-new\" is forbidden: User \"system:serviceaccount:monitoring:daily-check\" cannot get resource \"pods/log\""; return 1 ;;
            error) echo "Error from server (BadRequest): container \"chamber-bridge\" in pod \"im-new\" is waiting to start"; return 1 ;;
          esac ;;
        "-n claudecode logs im-new -c app --tail=500")
          [[ "$AMODE" == error ]] && { echo "Error from server (BadRequest): container \"app\" in pod \"im-new\" is waiting to start"; return 1; }
          cat "$W/atail" ;;
        "-n claudecode logs im-new -c app") cat "$W/afull" ;;
        *) echo "STUB: unexpected kubectl $*" >&2; return 99 ;;
      esac
    }
    '"$BLOCK"'
  ' 2>&1)"
  if grep -q 'STUB:' <<<"$out"; then fail "$name: the row asked something unexpected: $(grep 'STUB:' <<<"$out" | head -1)"; return; fi
  local lines; lines="$(grep -c '|im chamber|' <<<"$out")"
  if [[ "$lines" -ne 1 ]]; then fail "$name: expected exactly one record, got $lines: $out"; return; fi
  local got; got="$(grep '|im chamber|' <<<"$out")"
  local msg; msg="$(sed 's/^[a-z]*|im chamber|//' <<<"$got")"
  local rest t missing="" present=""
  rest="$texts"
  while [[ -n "$rest" ]]; do
    t="$(sed 's/ && .*//' <<<"$rest")"
    if [[ "$rest" == *" && "* ]]; then rest="$(sed 's/^[^&]* && //' <<<"$rest")"; else rest=""; fi
    grep -qF -- "$t" <<<"$msg" || missing="${missing} \"$t\""
  done
  rest="$nots"
  while [[ -n "$rest" ]]; do
    t="$(sed 's/ && .*//' <<<"$rest")"
    if [[ "$rest" == *" && "* ]]; then rest="$(sed 's/^[^&]* && //' <<<"$rest")"; else rest=""; fi
    grep -qF -- "$t" <<<"$msg" && present="${present} \"$t\""
  done
  local level; level="$(cut -d'|' -f1 <<<"$got")"
  if [[ "$level" != "$want" || -n "$missing" || -n "$present" ]]; then
    fail "$name: wanted $want${missing:+, with$missing}${present:+, without$present}; got: $got"
  else
    echo "PASS  $name  ->  $level: $(cut -c1-140 <<<"$msg")"
  fi
}

run_all() {
  run_case "0 deliver, online (jg-jcc2's line)" "$DEPLOY_CH" "$ONE" "$(st 8 deliver ok cust-jg-fixture yes)" ok "$GOODV" ok "" ok \
    "mode deliver, server ok && room cust-jg-fixture && online && signers 1, revoked 0" "not measured && also:"
  run_case "1 no im" "" "$ONE" "" ok "" ok "" skip "no im deployment"
  run_case "2 not attached" "$DEPLOY_PLAIN" "$ONE" "" ok "" ok "" skip "not attached to chamber"
  run_case "3 pods unlistable" "$DEPLOY_CH" "-" "" ok "" ok "" skip "im pods could not be listed"
  run_case "4 declared, not running" "$DEPLOY_CH" "{\"items\":[$(pod im-new -)]}" "" ok "" ok "" fail "none is running"
  run_case "5 bridge log forbidden" "$DEPLOY_CH" "$ONE" "" forbidden "" ok "" skip "no RBAC permission to read pods/log && not the same as clean"
  run_case "6 bridge log otherwise unreadable" "$DEPLOY_CH" "$ONE" "" error "" ok "" skip "chamber-bridge unreadable: Error from server (BadRequest)"
  run_case "7 no status line" "$DEPLOY_CH" "$ONE" "chamber-bridge: started" ok "$GOODV" ok "" skip "no chamber-status line in the last 200 lines && read fine: signers 1"
  run_case "8 status line too old (400 s at interval 20)" "$DEPLOY_CH" "$ONE" "$(st 400 deliver ok cust-jg-fixture yes)" ok "$GOODV" ok "" skip "the newest chamber-status line is 4 && s old (interval 20 s) && too old to judge" "mode deliver"
  run_case "9 status line inside the limit (330 s; the limit is 360)" "$DEPLOY_CH" "$ONE" "$(st 330 deliver ok cust-jg-fixture yes)" ok "$GOODV" ok "" ok "mode deliver, server ok"
  run_case "10 the limit follows the line's own interval (600 s old, interval 120)" "$DEPLOY_CH" "$ONE" "$(st 600 deliver ok cust-jg-fixture yes 120)" ok "$GOODV" ok "" ok "online"
  run_case "11 unconfigured: warn, with the bridge's reason" "$DEPLOY_CH" "$ONE" "$(echo 'chamber-bridge: incomplete — the token is absent (/etc/chamber/token)'; st 5 unconfigured unmeasured unmeasured unmeasured)" ok "$GOODV" ok "" warn \
    "attached but not configured && incomplete — the token is absent" "not measured"
  run_case "12 server unreachable" "$DEPLOY_CH" "$ONE" "$(st 5 deliver unreachable unmeasured unmeasured)" ok "$GOODV" ok "" fail "server=unreachable && no HTTP answer" "not measured"
  run_case "13 server refused" "$DEPLOY_CH" "$ONE" "$(st 5 observe refused unmeasured unmeasured)" ok "$GOODV" ok "" fail "server=refused && refused the credential"
  run_case "14 wrong room: both sides printed" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-other yes)" ok "$GOODV" ok "" fail "rooms=cust-other, expected exactly cust-jg-fixture"
  run_case "15 an extra room is not the expected room" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture,fac yes)" ok "$GOODV" ok "" fail "rooms=cust-jg-fixture,fac, expected exactly cust-jg-fixture"
  run_case "16 no room at all" "$DEPLOY_CH" "$ONE" "$(st 5 observe ok - no)" ok "$GOODV" ok "" fail "rooms=-, expected exactly cust-jg-fixture"
  run_case "17 rooms unmeasured (jg-jiahd's line): skip, not ok" "$DEPLOY_CH" "$ONE" "$(st 5 observe ok unmeasured unmeasured)" ok "$GOODV" ok "" skip "rooms=unmeasured && membership was not judged && read fine: mode observe, server ok"
  run_case "18 observe, online=no (jcom's line): ok, presence not judged" "$DEPLOY_CH" "$ONE" "$(st 5 observe ok cust-jg-fixture no)" ok "$GOODV" ok "" ok "observe mode, so not being online is the design (online=no, not judged)"
  run_case "19 deliver, online=no" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture no)" ok "$GOODV" ok "" fail "deliver mode and online=no"
  run_case "20 deliver, online unmeasured" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture unmeasured)" ok "$GOODV" ok "" skip "online=unmeasured — presence not judged"
  run_case "21 ssh-keygen missing" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture yes)" ok "$(vf 5 1 0 missing)" ok "" fail "sshkeygen=missing"
  run_case "22 signers=0: warn" "$DEPLOY_CH" "$ONE" "$(st 5 observe ok cust-jg-fixture no)" ok "$(vf 5 0 0 ok)" ok "" warn "signers=0 && cannot measure"
  run_case "23 signers unmeasured" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture yes)" ok "$(vf 5 unmeasured unmeasured ok)" ok "" skip "signers=unmeasured"
  run_case "24 revoked unmeasured is not a fault" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture yes)" ok "$(vf 5 2 unmeasured ok)" ok "" ok "signers 2, revoked unmeasured"
  run_case "25 verify line too old" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture yes)" ok "$(vf 900 1 0 ok)" ok "" skip "the newest chamber-verify-status line is 90 && s old — signer list not judged"
  run_case "26 no verify line, chamber-watch says why: warn" "$DEPLOY_CH" "$ONE" "$(st 5 observe ok cust-jg-fixture no)" ok "entrypoint: starting" ok "$(echo 'entrypoint: starting'; echo 'chamber-watch: curl is missing — not started')" warn \
    "chamber-watch: curl is missing — not started && not being reported"
  run_case "27 no verify line and no reason: skip" "$DEPLOY_CH" "$ONE" "$(st 5 observe ok cust-jg-fixture no)" ok "entrypoint: starting" ok "entrypoint: starting" skip "no chamber-watch line saying why"
  run_case "28 app log unreadable" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok cust-jg-fixture yes)" ok "" error "" skip "app unreadable && read fine: mode deliver, server ok"
  run_case "29 fail outranks warn and skip, and all three are named" "$DEPLOY_CH" "$ONE" "$(st 5 deliver ok unmeasured no)" ok "$(vf 5 0 0 ok)" ok "" fail \
    "deliver mode and online=no && also: signers=0 && not measured: rooms=unmeasured"
  run_case "30 unknown mode" "$DEPLOY_CH" "$ONE" "$(st 5 relay ok cust-jg-fixture yes)" ok "$GOODV" ok "" skip "mode=relay is not a value this row knows"
  run_case "31 an appended field does not move the others" "$DEPLOY_CH" "$ONE" "chamber-status ts=$(( NOW - 3 )) interval=20 mode=deliver server=ok rooms=cust-jg-fixture online=yes queue=4" ok "$GOODV" ok "" ok "room cust-jg-fixture && online"
  run_case "32 ts is not a number" "$DEPLOY_CH" "$ONE" "chamber-status ts=soon interval=20 mode=deliver server=ok rooms=cust-jg-fixture online=yes" ok "$GOODV" ok "" skip "no usable ts/interval"
  # jg-jiahd, 2026-11-24: the link drops for a beat or two every few minutes.
  # A row that read only the newest line was red or green by the second it ran.
  run_case "34 newest line unreachable, a clean line 45 s before it: judged by the clean line, the drop is counted" "$DEPLOY_CH" "$ONE" \
    "$(ln 85 observe ok cust-jg-fixture no; ln 65 observe ok cust-jg-fixture no; ln 45 observe ok cust-jg-fixture no; ln 25 observe ok unmeasured unmeasured; ln 5 observe unreachable unmeasured unmeasured)" ok "$GOODV" ok "" ok \
    "mode observe, server ok && room cust-jg-fixture && intermittent: of 5 status lines in the log tail, 1 had no server and 1 could not read room names" "server=unreachable"
  run_case "35 newest line cannot read rooms, a clean line before it: ok, counted" "$DEPLOY_CH" "$ONE" \
    "$(ln 45 deliver ok cust-jg-fixture yes; ln 5 deliver ok unmeasured unmeasured)" ok "$GOODV" ok "" ok "room cust-jg-fixture && online && 0 had no server and 1 could not read room names"
  run_case "36 down for the whole window: the last clean line is too old to count" "$DEPLOY_CH" "$ONE" \
    "$(ln 500 deliver ok cust-jg-fixture yes; ln 300 deliver unreachable unmeasured unmeasured; ln 150 deliver unreachable unmeasured unmeasured; ln 5 deliver unreachable unmeasured unmeasured)" ok "$GOODV" ok "" fail \
    "server=unreachable && on every one of the 3 fresh status line(s)" "online"
  run_case "37 no clean line in the window, and not down throughout: not judged" "$DEPLOY_CH" "$ONE" \
    "$(ln 45 observe ok unmeasured unmeasured; ln 5 observe unreachable unmeasured unmeasured)" ok "$GOODV" ok "" skip "no fresh line read both the server and the room names (1 of 2 fresh lines had no server)"
  run_case "38 the clean line that is judged still has to be the right room" "$DEPLOY_CH" "$ONE" \
    "$(ln 45 deliver ok cust-other yes; ln 5 deliver unreachable unmeasured unmeasured)" ok "$GOODV" ok "" fail "rooms=cust-other, expected exactly cust-jg-fixture"
  run_case "39 unconfigured now is not rescued by a clean line from before" "$DEPLOY_CH" "$ONE" \
    "$(ln 45 deliver ok cust-jg-fixture yes; ln 5 unconfigured unmeasured unmeasured unmeasured)" ok "$GOODV" ok "" warn "attached but not configured"
  run_case "33 newest running pod is read" "$DEPLOY_CH" "{\"items\":[$(pod im-old 2026-11-20T00:00:00Z),$(pod im-new 2026-11-24T09:37:50Z)]}" "$(st 5 deliver ok cust-jg-fixture yes)" ok "$GOODV" ok "" ok "online"
}

if [[ "${1:-}" != "--self-test" ]]; then
  run_all
  [[ $rc -eq 0 ]] && echo "ok — row 33 gives skip/ok/warn/fail as specified across 40 cases (k8scc format v1), and the pods/log grant is where the row reads"
  exit $rc
fi

# --self-test: cell 0 is the unmutated row and must be green. Each mutation
# must first be shown to have changed the file, then turn the cases red, and
# the red must name the case the mutation was aimed at.
ORIG_CM="$CM"
cell() {  # label | sed expression | case that must fail ("" = expect green)
  local label="$1" expr="$2" want="$3" m="$WORK/mut.yaml" out mrc
  if [[ -z "$expr" ]]; then cp "$ORIG_CM" "$m"; else sed "$expr" "$ORIG_CM" > "$m"; fi
  if [[ -n "$expr" ]] && cmp -s "$ORIG_CM" "$m"; then echo "CANNOT MEASURE — $label: the mutation did not change the file"; return 2; fi
  out="$(CHAMBER_ROW_CM="$m" bash "${BASH_SOURCE[0]}" 2>&1)"; mrc=$?
  if [[ -z "$want" ]]; then
    [[ $mrc -eq 0 ]] && { echo "PASS  $label: green"; return 0; }
    echo "FAIL — $label: the unmutated row is not green (rc=$mrc): $(grep -m1 -E '^(FAIL|cannot)' <<<"$out")"; return 1
  fi
  if [[ $mrc -eq 1 ]] && grep -q "^FAIL — $want" <<<"$out"; then echo "PASS  $label: red at case $want"; return 0; fi
  echo "FAIL — $label: wanted red at case $want, got rc=$mrc: $(grep -m2 -E '^(FAIL|cannot)' <<<"$out" | tr '\n' ' ')"; return 1
}
src=0
run_cell() { cell "$@"; local r=$?; (( r > src )) && src=$r; return 0; }
run_cell "cell 0 unmutated" "" ""
run_cell "m1 observe judged like deliver" 's/if \[\[ "\$CH_MODE" == observe \]\]; then/if [[ "$CH_MODE" == never ]]; then/' "18 "
run_cell "m2 the age limit removed" 's/if (age > 3 \* iv + 300) printf "%d", age/if (age > 999999) printf "%d", age/' "8 "
run_cell "m3 the limit ignores the line's interval" 's/if (age > 3 \* iv + 300) printf/if (age > 3 * 20 + 300) printf/' "10 "
run_cell "m4 rooms unmeasured accepted" 's/elif \[\[ "\$CH_ROOMS" == unmeasured || -z "\$CH_ROOMS" \]\]; then/elif [[ "$CH_ROOMS" == never ]]; then/' "17 "
run_cell "m5 the expected room taken from the bridge" 's/CH_WANT="cust-\${CLUSTER_NAME}"/CH_WANT="$CH_ROOMS"/' "14 "
run_cell "m6 signers=0 not warned" 's/if \[\[ "\$CH_SIGNERS" == 0 \]\]; then/if [[ "$CH_SIGNERS" == never ]]; then/' "22 "
run_cell "m7 deliver online=no not failed" 's/no) CH_FAILS+=("deliver mode and online=no/no) CH_OKS+=("deliver mode and online=no/' "19 "
run_cell "m8 the oldest status line read, not the newest" "s/CH_S=\$(grep '^chamber-status ' <<<\"\$CH_BLOG\" | tail -1)/CH_S=\$(grep '^chamber-status ' <<<\"\$CH_BLOG\" | head -1)/" "0 "
run_cell "m9 unconfigured line deleted" '/^ *unconfigured)$/,/the bridge has opened no connection") ;;$/d' "11 "
run_cell "m10 ssh-keygen missing not failed" 's/missing) CH_FAILS+=("sshkeygen=missing/missing) CH_OKS+=("sshkeygen=missing/' "21 "
run_cell "m11 only the newest line judged" 's/if \[\[ "\$CH_MODE" != unconfigured \&\& -n "\$CH_PICK" \]\]; then/if [[ "$CH_MODE" == never ]]; then/' "34 "
run_cell "m12 a stale clean line is allowed to speak" 's/now - f\["ts"\] <= 3 \* f\["interval"\] + 300/now - f["ts"] <= 999999/' "36 "
run_cell "m13 a clean line rescues an unconfigured bridge" 's/if \[\[ "\$CH_MODE" != unconfigured \&\& -n "\$CH_PICK" \]\]; then/if [[ -n "$CH_PICK" ]]; then/' "39 "
run_cell "m14 the intermittent count dropped" 's/if (( CH_DOWNS + CH_NOROOM > 0 )); then/if (( CH_DOWNS + CH_NOROOM > 999 )); then/' "34 "
CHAMBER_ROW_CM="$WORK/absent.yaml" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; [[ $? -eq 2 ]] && echo "PASS  c1 ConfigMap unreadable: cannot measure (2)" || { echo "FAIL — c1 an unreadable ConfigMap did not read as cannot measure"; src=1; }
sed '/# 33\. im chamber/d' "$ORIG_CM" > "$WORK/norow.yaml"; CHAMBER_ROW_CM="$WORK/norow.yaml" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; [[ $? -eq 2 ]] && echo "PASS  c2 row header gone: cannot measure (2)" || { echo "FAIL — c2 a missing row did not read as cannot measure"; src=1; }
[[ $src -eq 0 ]] && echo "self-test ok: 17 cells (cell 0 green, 14 mutations each red at the case it was aimed at, 2 cannot-measure)"
exit $src
