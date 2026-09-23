#!/usr/bin/env bash
# Assert that daily-check's kubectl/API-server skew row discriminates in BOTH
# directions, and that it never turns the whole cluster red.
#
# ferry133/jg-base#130: nobody was watching this number. Alpine v3.20's kubectl
# package is 1.30.9; jg-jiahd's API server was measured at v1.36.0 on
# 2026-09-22 — six minors against a supported skew of one — and two workloads
# installed it that way with nothing in this repo able to say so.
#
# ⚠️ The row asks the BINARY (`kubectl version -o json`), not a manifest and
# not the image's own ops-toolchain.json. That file is a record written by an
# execution at build time; replace the binary in a later layer and it keeps
# reporting the old number while still reading exactly like a reading
# (ferry133/k8scc#14, #17).
#
# Sources the real block out of the ConfigMap rather than restating it: a copy
# here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-kubectl-skew-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cannot measure: jq is missing"; exit 2; }

# Anchored on the row's own `if`, and on the next row header, so the anchors
# hold nothing the mutations change.
BLOCK="$(awk '
    /^[[:space:]]*if ! command -v kubectl >\/dev\/null 2>&1; then/ { grabbing = 1 }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: the skew row was not found in the ConfigMap"; exit 2; }
grep -q 'kubectl version skew' <<<"$BLOCK" || { echo "cannot measure: extracted block is not the skew row"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# One run: `c`/`s` are the versions a stubbed kubectl reports; `mode` picks the
# failure to simulate. Each case is its own subshell.
run() {
  local mode="$1" c="${2:-}" s="${3:-}"
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
    case "$mode" in
      nokubectl) command() { return 1; } ;;
      apidown)   kubectl() { return 1; } ;;
      *)         kubectl() { jq -nc --arg c "$c" --arg s "$s" \
                    '{clientVersion:{gitVersion:$c},serverVersion:{gitVersion:$s}}'; } ;;
    esac
    eval "$BLOCK"
    printf '%s\n' "${SUMMARY[@]}"
    echo "counts=${FAIL_COUNT}/${WARN_COUNT}/${SKIP_COUNT}"
  ) 2>/dev/null
}

lvl() { cut -d'|' -f1 <<<"$1" | head -1; }

# --- the defect: a big skew must be visible.
out="$(run ok v1.30.9 v1.36.0)"
[[ "$(lvl "$out")" == WARN ]] || fail "six minors apart did not warn (got '$(lvl "$out")') — that is exactly the state measured on 2026-09-22 with nothing able to say so"
grep -q '1.30.9' <<<"$out" && grep -q '1.36.0' <<<"$out" \
  || fail "the warning does not carry both versions: $(tr '\n' ' ' <<<"$out")"
grep -qE '[0-9]+ minors' <<<"$out" || fail "the warning does not say how far apart they are"

# --- the OTHER direction, which is what stops this being 'always warn'.
for pair in "v1.36.0 v1.36.0" "v1.36.0 v1.35.4" "v1.35.4 v1.36.0"; do
  set -- $pair
  out="$(run ok "$1" "$2")"
  [[ "$(lvl "$out")" == OK ]] || fail "client $1 against server $2 is within the supported skew but reported '$(lvl "$out")'"
  grep -q "$1" <<<"$out" && grep -q "$2" <<<"$out" \
    || fail "the ok row for $1/$2 does not print both versions — 'compatible' without the numbers cannot be checked by whoever reads the report"
done

# --- two minors is the first failing distance; one is the last passing one.
[[ "$(lvl "$(run ok v1.36.0 v1.34.0)")" == WARN ]] || fail "two minors apart did not warn — the boundary is off by one"
[[ "$(lvl "$(run ok v1.34.0 v1.36.0)")" == WARN ]] || fail "two minors apart (client behind) did not warn"

# --- three distinct not-measured reasons, and none of them is `ok`.
# ⚠️ Collected into a file, not an associative-array subscript. The first
# version used `SEEN["$msg"]=1` and bash rejected the subscripts outright
# ("bad array subscript") because these messages carry parentheses, commas and
# an em-dash -- and the loop carried on, leaving the count at 0 while the
# distinctness check still reported a number. Caught by a mutation that
# collapsed two reasons into one and STILL PASSED.
REASONS="$(mktemp)"
for m in nokubectl apidown; do
  out="$(run "$m")"
  [[ "$(lvl "$out")" == SKIP ]] || fail "mode '$m' reported '$(lvl "$out")' instead of skip — a question that could not be asked is not a pass"
  cut -d'|' -f3 <<<"$out" | head -1 >> "$REASONS"
done
out="$(run ok "garbage" "v1.36.0")"
[[ "$(lvl "$out")" == SKIP ]] || fail "an unparseable client version reported '$(lvl "$out")' instead of skip"
cut -d'|' -f3 <<<"$out" | head -1 >> "$REASONS"

N_LINES=$(wc -l <"$REASONS" | tr -d ' ')
N_UNIQ=$(sort -u "$REASONS" | grep -c . || true)
rm -f "$REASONS"
[[ "$N_LINES" -eq 3 ]] \
  || { echo "cannot measure: collected ${N_LINES} skip messages, expected 3 — the harness did not run every case"; exit 2; }
[[ "$N_UNIQ" -eq 3 ]] \
  || fail "the three not-measured reasons collapse into ${N_UNIQ} distinct message(s) — several states printing one sentence is how #108 stayed invisible for 8 days"

# --- it must never fail the cluster: FAIL_COUNT gates the dead-man (#6).
for args in "ok v1.30.9 v1.36.0" "ok v1.36.0 v1.36.0" "nokubectl" "apidown"; do
  out="$(run $args)"
  [[ "$(grep -o 'counts=[0-9]*' <<<"$out")" == "counts=0" ]] \
    || fail "case '$args' recorded a FAIL — this row must never fail: FAIL_COUNT marks the whole cluster Down on healthchecks.io"
done

if [[ $rc -eq 0 ]]; then
  echo "PASS — six minors warns with both versions and the distance; 0 and 1 minor pass printing both;"
  echo "       two minors is the first warning; three distinct skip reasons; never records fail"
fi
exit $rc
