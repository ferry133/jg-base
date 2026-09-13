#!/usr/bin/env bash
# Assert that daily-check's `record` helper does not silently drop an `ok`
# row's message.
#
# ferry133/jg-base#104: the `ok` branch appended only "✅ ${name}", so a third
# argument passed to `record ok` went nowhere — not into SUMMARY, not into
# DETAILS (ok rows never enter DETAILS at all), and with no error. Exactly one
# caller did this, check 17a at `record ok "Discovered LAN pool present but
# unused" "no Service holds ..."`, so the sentence explaining WHY an unused
# pool is benign had been absent from every cluster's report since 2026-08-19
# (e1199d2) — about 25 days, and nothing said so.
#
# The acceptance its reviewer set (jgct-handler [c8c318], jg-base#104): the PR
# must carry a runnable regression, because this defect survived 25 days
# precisely because nothing spoke when it happened. A fix with no guard leaves
# the next silent regression equally unattributable.
#
# That reviewer also rejected the shape this author first proposed — making
# `record` fail loudly when an `ok` msg would be dropped, ON TOP of printing
# it. Once `ok` prints the msg, nothing is ever dropped, so that branch could
# never fire: a guard that cannot fail reads exactly like a guard that passes.
# The fix is therefore the one-line `${msg:+ ...}` and this file, nothing more.
#
# Sources the real `record()` out of the ConfigMap rather than restating it: a
# copy here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-record-ok-keeps-msg.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }

# Extract record() by matching its opening line and the closing brace at the
# same indent — not by line number, which drifts with every row added above.
BLOCK="$(awk '
  /^[[:space:]]*record\(\) \{/ { ind = match($0, /[^ ]/); grabbing = 1 }
  grabbing { print }
  grabbing && /^[[:space:]]*\}[[:space:]]*$/ && match($0, /[^ ]/) == ind { exit }
' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: record() not found in the ConfigMap"; exit 2; }
grep -q 'SUMMARY+=' <<<"$BLOCK" || { echo "cannot measure: extracted block is not record()"; exit 2; }

WARN_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0; SUMMARY=(); DETAILS=()
eval "$BLOCK" || { echo "cannot measure: extracted record() did not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

record ok   "OK ROW"       "OK-MSG-SENTINEL"
record warn "WARN ROW"     "WARN-MSG-SENTINEL"
record ok   "BARE OK ROW"
ALL="$(printf '%s\n' "${SUMMARY[@]}" "${DETAILS[@]}")"

# 1. The regression itself. This is the case that must fail before the fix.
grep -q 'OK-MSG-SENTINEL' <<<"$ALL" \
  || fail "an ok row's message was dropped — #104 has regressed"

# 2. Positive control. Passes both before and after the fix; if this ever
#    fails, the harness is broken and case 1's result means nothing.
grep -q 'WARN-MSG-SENTINEL' <<<"$ALL" \
  || { echo "cannot measure: warn control lost its message — harness broken"; exit 2; }

# 3. The other 35 `record ok` occurrences pass no message. They must render
#    byte-identically, with no orphan separator left by the substitution.
grep -qx '✅ BARE OK ROW' <<<"$ALL" \
  || fail "a message-less ok row changed shape: $(grep 'BARE OK ROW' <<<"$ALL")"

# 4. Negative control: proves the matcher can report absence at all.
grep -q 'NEVER-EMITTED-SENTINEL' <<<"$ALL" \
  && fail "negative control matched something that was never recorded"

if (( rc == 0 )); then
  echo "ok — 4 cases match: ok keeps its message, warn control intact, message-less ok rows unchanged, absence detectable"
fi
exit "$rc"
