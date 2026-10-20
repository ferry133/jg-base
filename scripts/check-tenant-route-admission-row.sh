#!/usr/bin/env bash
# Assert daily-check row 30 (tenant route admission, ferry133/jg-base#205)
# gives every verdict it claims, from the real block in the ConfigMap.
#
# The kubectl stub answers ONLY the two things the row does: list namespaces
# with -l jg.tenant, and `create --dry-run=server -o name -f -`. It reads the
# object the row sends on stdin and checks it (namespace, generateName, one
# hostname) before answering by hostname. Anything else fails loudly: a stub
# that ignores its arguments is a constant, and a row that dropped
# --dry-run=server, or probed the wrong namespace, would pass.
#
# Usage: scripts/check-tenant-route-admission-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
RBAC="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/rbac.yaml"
[[ -r "$CM" && -r "$RBAC" ]] || { echo "cannot measure: daily-check app files not readable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cannot measure: jq is missing"; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/route-admission-row.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

BLOCK="$(awk '
    /^[[:space:]]*# 30\. Tenant route admission/ { grabbing = 1 }
    grabbing && /^[[:space:]]*# [0-9]+[a-z]?\. / && !/# 30\./ { exit }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: row 30 was not found in the ConfigMap"; exit 2; }
# Anchor on the row's own helper, NOT on `--dry-run=server`: dropping that flag
# is the regression this guard exists for, and it must read red, not "cannot
# measure" (the first version anchored there and did exactly that).
grep -q 'tra_probe()' <<<"$BLOCK" || { echo "cannot measure: extracted block is not row 30"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# The grant the row needs, and no more than it needs.
HR_VERBS="$(awk '/resources: \["httproutes"\]/ { getline; print }' "$RBAC")"
[[ "$HR_VERBS" == *'verbs: ["create"]'* ]] \
  || fail "rbac.yaml does not grant exactly create on httproutes (got: ${HR_VERBS:-nothing}) — the row would always skip, or the grant grew"

ns() { printf '{"metadata":{"name":"%s","labels":{"jg.tenant":"%s"}}}' "$1" "$2"; }

DENY_NOPARAMS="The httproutes \"daily-check-probe-x\" is invalid: : ValidatingAdmissionPolicy 'tenant-httproute-hostnames' with binding 'tenant-httproute-hostnames' denied request: failed to configure binding: no params found for policy binding with \`Deny\` parameterNotFoundAction"
DENY_SUFFIX="The httproutes \"daily-check-probe-x\" is invalid: : ValidatingAdmissionPolicy 'tenant-httproute-hostnames' with binding 'tenant-httproute-hostnames' denied request: tenant HTTPRoute hostnames must all end in \".acme.example.test\""
DENY_RBAC='Error from server (Forbidden): error when creating "STDIN": httproutes.gateway.networking.k8s.io is forbidden: User "system:serviceaccount:monitoring:daily-check" cannot create resource "httproutes" in API group "gateway.networking.k8s.io" in the namespace "acme"'
OTHER='error: resource mapping not found for name: "" namespace: "acme" from "STDIN": no matches for kind "HTTPRoute" in version "gateway.networking.k8s.io/v1"'

# case | ns items | refuse ns list (yes|no) | domain (- = unset) | want ns | good answer | bad answer | want level | want texts (" && ")
#   answers: ok | noparams | suffix | rbac | other
run_case() {
  local name="$1" items="$2" refuse="$3" domain="$4" wantns="$5" good="$6" bad="$7" want="$8" texts="$9"
  rm -rf "$WORK/c"; mkdir -p "$WORK/c"
  printf '{"items":[%s]}' "$items" > "$WORK/c/ns.json"
  local envdom=(); [[ "$domain" != "-" ]] && envdom=(SECRET_DOMAIN="$domain")
  out="$(env -u SECRET_DOMAIN "${envdom[@]}" REFUSE="$refuse" W="$WORK/c" WANTNS="$wantns" GOOD="$good" BAD="$bad" \
    DENY_NOPARAMS="$DENY_NOPARAMS" DENY_SUFFIX="$DENY_SUFFIX" DENY_RBAC="$DENY_RBAC" OTHER="$OTHER" bash -c '
    set -uo pipefail
    record() { echo "$1|$2|${3:-}"; }
    answer() {
      case "$1" in
        ok) echo "httproute.gateway.networking.k8s.io/daily-check-probe-x created (server dry run)"; return 0 ;;
        noparams) echo "$DENY_NOPARAMS"; return 1 ;;
        suffix) echo "$DENY_SUFFIX"; return 1 ;;
        rbac) echo "$DENY_RBAC"; return 1 ;;
        other) echo "$OTHER"; return 1 ;;
      esac
    }
    kubectl() {
      case "$*" in
        "get namespaces -l jg.tenant -o json") [[ "$REFUSE" == yes ]] && return 1; cat "$W/ns.json" ;;
        "create --dry-run=server -o name -f -")
          local obj host; obj="$(cat)"
          echo "$obj" | jq -e --arg ns "$WANTNS" ".kind == \"HTTPRoute\" and .metadata.namespace == \$ns and .metadata.generateName == \"daily-check-probe-\" and (.metadata.name == null) and (.spec.hostnames | length == 1)" >/dev/null \
            || { echo "STUB: unexpected object: $obj" >&2; return 99; }
          host="$(echo "$obj" | jq -r ".spec.hostnames[0]")"
          echo "$host" >> "$W/hosts"
          case "$host" in
            probe.*.*.*) answer "$GOOD" ;;
            probe.*) answer "$BAD" ;;
            *) echo "STUB: unexpected hostname $host" >&2; return 99 ;;
          esac ;;
        *) echo "STUB: unexpected kubectl $*" >&2; return 99 ;;
      esac
    }
    '"$BLOCK"'
  ' 2>&1)"
  if grep -q 'STUB:' <<<"$out"; then fail "$name: the row asked something unexpected: $(grep 'STUB:' <<<"$out" | head -1)"; return; fi
  local lines; lines="$(grep -c '|Tenant route admission|' <<<"$out")"
  if [[ "$lines" -ne 1 ]]; then fail "$name: expected exactly one record, got $lines: $out"; return; fi
  local got; got="$(grep '|Tenant route admission|' <<<"$out")"
  local msg="${got#*|Tenant route admission|}" rest="$texts" t missing=""
  while [[ -n "$rest" ]]; do
    t="${rest%% && *}"
    if [[ "$rest" == *" && "* ]]; then rest="${rest#* && }"; else rest=""; fi
    grep -qF -- "$t" <<<"$msg" || missing="${missing} \"$t\""
  done
  if [[ "${got%%|*}" != "$want" || -n "$missing" ]]; then
    fail "$name: wanted $want with$missing, got: $got"
  else
    echo "PASS  $name  ->  ${got%%|*}: $msg"
  fi
}

D=example.test
ACME="$(ns acme acme)"
ZETA="$(ns zeta zeta)"
run_case "0 both as expected" "$ACME" no $D acme ok suffix ok "in acme: probe.acme.example.test accepted, probe.example.test refused"
run_case "1 no tenants" "" no $D acme ok suffix skip "no tenants declared"
run_case "2 namespaces unreadable" "" yes $D acme ok suffix skip "could not be listed"
run_case "3 domain unset" "$ACME" no - acme ok suffix skip "SECRET_DOMAIN is unset"
run_case "4 no params found (the #205 state)" "$ACME" no $D acme noparams noparams fail "EVERY tenant route is refused && restart kube-apiserver on every control-plane node && do not recreate the policy && no params found"
run_case "5 compliant refused by the policy otherwise" "$ACME" no $D acme suffix suffix fail "was refused by the hostname policy && must all end in"
run_case "6 RBAC refused" "$ACME" no $D acme rbac rbac skip "no RBAC permission && not the same as clean"
run_case "7 other error" "$ACME" no $D acme other other skip "not the policy && no matches for kind"
run_case "8 outside admitted (policy absent)" "$ACME" no $D acme ok ok fail "probe.example.test in acme) was admitted && not enforcing"
run_case "9 outside refused for another reason" "$ACME" no $D acme ok other skip "enforcement was not shown && no matches for kind"
run_case "10 first tenant by name, label from that namespace" "$ZETA,$(ns acme-ns acme)" no $D acme-ns ok suffix ok "in acme-ns: probe.acme.example.test accepted"
run_case "11 red outranks: no params even if outside admitted" "$ACME" no $D acme noparams ok fail "no params found"

[[ $rc -eq 0 ]] && echo "ok — row 30 gives skip/ok/fail as specified across 12 cases, dry-run only, and rbac.yaml grants exactly create on httproutes"
exit $rc
