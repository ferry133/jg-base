#!/usr/bin/env bash
# Assert that a daily-check run whose report was NOT delivered says so on every
# channel it still has, and that a delivered run is unchanged.
#
# ferry133/jg-base#114: msmtp failing produced one line on stderr and nothing
# else. The run then sent a SUCCESS dead-man ping and exited 0, so on the day
# the mail broke every outside channel said the cluster was fine. That is worse
# than #112's silence: #112's cluster was never registered on healthchecks.io
# and could neither go red nor green, while this one actively emits a signal
# saying "I am well".
#
# Two mechanisms carry it, and the point is that their premises DIFFER — two
# defences sharing a premise are one defence:
#
#   /fail ping    needs HEALTHCHECKS_PING_URL; survives the Job's
#                 ttlSecondsAfterFinished: 86400 because healthchecks.io keeps
#                 history
#   exit 75       needs nothing at all; covers the combination FO-handler
#                 [f92b04] named on #114 — SMTP set, ping URL unset, which the
#                 template permits because `default('')` does not bind the five
#                 daily_check_* fields together
#
# Case 6 is the half that is easy to lose later: a mailer outage must NOT enter
# FAIL_COUNT. FAIL_COUNT says "this cluster is unhealthy" and gates the
# dead-man; fold the two together and neither stays answerable.
#
# Sources the three real blocks out of the ConfigMap rather than restating
# them: a copy here would drift, and the copy that drifts keeps passing.
#
# ⚠️ DELIBERATELY NOT ASSERTED, so that the next person does not "fix" it:
# deleting the top-of-script `MAIL_DELIVERED=0` initialiser leaves this suite
# green, and that is correct. The send block sets the flag on BOTH paths, so
# that initialiser carries no behaviour; an assertion on it would be flagging a
# line that does nothing, and a guard that fires on correct code is the one
# that gets switched off (#6). Verified as a mutation and left passing on
# purpose (ferry133/jg-base#115, agreed by the acceptor FO-handler [f92b04]).
# If you make the initialiser load-bearing again — by removing either in-block
# assignment — cases 1b and 1c fail, which is the assertion that actually
# matters here.
#
# ⚠️ THIS FILE ALONE DOES NOT SECURE THE THREE EXIT CODES. It pins 75 for an
# undelivered report; `check-unconfigured-exits-nonzero.sh` pins 78 for an
# unconfigured cluster. Swapping the two constants is caught only by the
# corresponding file, so the pair is what makes 0/75/78 distinguishable rather
# than merely "non-zero" (measured by FO-handler [f92b04] as mutations M1/M2 on
# #115). Whoever deletes one of these should know what they are deleting.
#
# Usage: scripts/check-mail-failure-is-visible.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "cannot measure: awk is missing"; exit 2; }

# The three blocks are delimited by the script's own `==>` section headers.
# Anchoring on those rather than on anything inside is deliberate: an anchor
# that moves with the code under test turns a real regression into "cannot
# measure", which is how #108 stayed green for 8 days.
section() {
  awk -v start="$1" -v stop="$2" '
    $0 ~ start { grabbing = 1 }
    grabbing && stop != "" && $0 ~ stop { exit }
    grabbing && /^[^[:space:]]/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //'
}

SEND="$(section '==> Sending email to' '==> Pinging healthchecks.io')"
PING="$(section '==> Pinging healthchecks.io' '==> Done\.')"
TAIL="$(section '==> Done\.' '')"
for pair in "SEND:$SEND" "PING:$PING" "TAIL:$TAIL"; do
  n="${pair%%:*}"; b="${pair#*:}"
  [[ -n "$b" ]] || { echo "cannot measure: the $n block was not found in the ConfigMap"; exit 2; }
  bash -n <<<"$b" || { echo "cannot measure: the $n block does not parse"; exit 2; }
done

rc=0
fail() { echo "FAIL — $1"; rc=1; }

BODY="$(mktemp)"; printf 'report body\n' >"$BODY"
trap 'rm -f "$BODY" "$SEND_ERR"' EXIT

# Run the send block against a mailer that succeeds or fails, and report the
# resulting MAIL_DELIVERED plus what reached stderr. Each case is its own
# subshell so nothing leaks into the next.
# NOTE: stderr is written to a file with its LINE STRUCTURE INTACT, and the
# assertions below ask whether one line carries both the marker and the reason.
# An earlier version collapsed it with `tr -d '\n'` and the suite then passed a
# mutation that removed the `2>"$MAIL_ERR_FILE"` capture entirely: the reason
# still reached stderr by another route, so "somewhere in stderr" could not tell
# the two apart. The instrument's own formatting had destroyed the distinction.
SEND_ERR="$(mktemp)"
send_probe() {
  local outcome="$1"
  : >"$SEND_ERR"
  (
    FAIL_COUNT=0; MAIL_DELIVERED=0
    NOTIFY_EMAIL_TO="a@x,b@x"; BODY_FILE="$BODY"
    if [[ "$outcome" == ok ]]; then
      msmtp() { return 0; }
    else
      msmtp() { echo "authentication failed SENTINEL-REASON" >&2; return 1; }
    fi
    eval "$SEND" 2>"$SEND_ERR"
    echo "delivered=${MAIL_DELIVERED}"
  )
}

# Run the ping block with a curl that records the URL it was given.
ping_probe() {
  local delivered="$1" failcount="$2" url="$3"
  (
    MAIL_DELIVERED="$delivered"; FAIL_COUNT="$failcount"; HEALTHCHECKS_PING_URL="$url"
    curl() { for a in "$@"; do case "$a" in https://*) echo "CALLED $a" ;; esac; done; return 0; }
    eval "$PING"
  ) 2>&1 | grep -oE 'CALLED [^ ]+' | sed 's/^CALLED //' | head -1
}

tail_exit() { ( FAIL_COUNT="$1"; MAIL_DELIVERED="$2"; eval "$TAIL" ) >/dev/null 2>&1; echo $?; }

# ------------------------------------------------------------------ the defect
# 1. A failed send must be recorded, not merely mentioned.
got="$(send_probe fail)"
grep -q 'delivered=0' <<<"$got" || fail "a failed send left MAIL_DELIVERED unset or true: $got"
grep -q 'ERROR.*SENTINEL-REASON' "$SEND_ERR" \
  || fail "the ERROR line does not carry the mailer's own words — 'msmtp returned non-zero' alone cannot separate a bad password from blocked egress. stderr was: $(tr '\n' '|' <"$SEND_ERR")"

# 1b. Positive control on the same block: a successful send must set the flag.
#     Without this, deleting `MAIL_DELIVERED=1` would leave every case above
#     passing while no run on earth could ever report a delivered report.
got="$(send_probe ok)"
grep -q 'delivered=1' <<<"$got" \
  || fail "a SUCCESSFUL send did not set MAIL_DELIVERED — every run would now ping /fail and exit 75: $got"

# 1c. The send block must be self-sufficient: run it with MAIL_DELIVERED unset
#     and `set -u` on. If it relies on an initialiser elsewhere in the script,
#     a failed send aborts the run before the /fail ping — losing the channel
#     this fix adds, and losing it by crashing rather than by saying anything.
got="$(
  (
    set -u
    FAIL_COUNT=0
    unset MAIL_DELIVERED
    NOTIFY_EMAIL_TO="a@x"; BODY_FILE="$BODY"
    msmtp() { echo "boom" >&2; return 1; }
    eval "$SEND" 2>/dev/null
    echo "delivered=${MAIL_DELIVERED}"
  ) 2>/dev/null
)"
grep -q 'delivered=0' <<<"$got" \
  || fail "the send block does not set MAIL_DELIVERED itself — with the initialiser gone, a failed send aborts under set -u before the /fail ping: ${got:-<crashed>}"

# 2. An undelivered report pings /fail EVEN WITH NO FAILING ROWS. This is the
#    case that was green before #114.
got="$(ping_probe 0 0 https://hc.example/abc)"
[[ "$got" == */fail ]] \
  || fail "mail undelivered with 0 failing rows pinged '${got:-<nothing>}' — the dead-man still says the cluster is fine on the day the report vanished"

# 3. Delivered + failing rows still pings /fail (unchanged behaviour).
got="$(ping_probe 1 2 https://hc.example/abc)"
[[ "$got" == */fail ]] || fail "delivered with 2 failing rows pinged '${got:-<nothing>}', expected /fail"

# 4. Positive control: delivered + clean still pings SUCCESS. Without this,
#    "always ping /fail" would satisfy cases 2 and 3.
got="$(ping_probe 1 0 https://hc.example/abc)"
[[ "$got" == "https://hc.example/abc" ]] \
  || fail "a clean delivered run pinged '${got:-<nothing>}', expected the success URL — the dead-man would fire every day and get switched off (#6)"

# 5. The exit status carries it, and distinguishably.
got="$(tail_exit 0 0)"
[[ "$got" -eq 75 ]] \
  || fail "an undelivered report exited $got, expected 75 (sysexits EX_TEMPFAIL) — with no ping URL this is the ONLY channel left, and a bare 1 cannot be told apart from a crash or from #112's 78"
got="$(tail_exit 3 1)"
[[ "$got" -eq 0 ]] \
  || fail "a delivered run with 3 failing rows exited $got, not 0 — Job status has become a second copy of cluster health (#6)"

# 6. The mailer outage must not be folded into FAIL_COUNT.
grep -qE 'FAIL_COUNT|record (fail|warn|ok|skip)' <<<"$SEND" \
  && fail "the send block now touches FAIL_COUNT or record — a mailer outage would read as an unhealthy cluster, and a sick cluster whose mail worked would be indistinguishable from it"

# 7. FO-handler's combination: SMTP set, ping URL unset. Nothing is pinged --
#    that is correct, there is nowhere to ping -- but the run must not end up
#    silent overall, which is case 5's 75.
got="$(ping_probe 0 0 "")"
[[ -z "$got" ]] || fail "with no ping URL the block still called out to '${got}'"

# --------------------------------------------------- can this script fail?
# Rebuild the pre-#114 blocks and assert the cases above catch them. A guard
# that cannot fail reads exactly like one that passes.
unmeasurable() { if [[ $rc -eq 0 ]]; then echo "cannot measure: $1"; exit 2; else echo "note: $1 (an assertion already failed, reporting that)"; fi; }

# awk, not a sed range: BSD sed rejects `/a/,/b/{/b/!d}` ("extra characters at
# the end of d command"), and this repo has been bitten by BSD/GNU sed and awk
# differences before. Drops the first branch and promotes the `elif`.
OLD_PING="$(awk '
    /if \[\[ \$MAIL_DELIVERED -eq 0 \]\]/ { skip = 1 }
    skip && /elif \[\[ \$FAIL_COUNT/ { skip = 0; sub(/elif/, "if"); print; next }
    skip { next }
    { print }
  ' <<<"$PING")"
if [[ "$OLD_PING" == "$PING" ]] || ! bash -n <<<"$OLD_PING" 2>/dev/null; then
  unmeasurable "could not rebuild the pre-#114 ping block"
else
  CTRL="$( ( MAIL_DELIVERED=0; FAIL_COUNT=0; HEALTHCHECKS_PING_URL=https://hc.example/abc
             curl() { for a in "$@"; do case "$a" in https://*) echo "CALLED $a" ;; esac; done; return 0; }
             eval "$OLD_PING" ) 2>&1 | grep -oE 'CALLED [^ ]+' | sed 's/^CALLED //' | head -1 )"
  [[ "$CTRL" == "https://hc.example/abc" ]] \
    || fail "negative control is broken: the pre-#114 ping block pinged '${CTRL:-<nothing>}' instead of the success URL, so case 2 is not measuring what it claims"
fi

OLD_TAIL="$(awk '
    /if \[\[ \$MAIL_DELIVERED -eq 0 \]\]/ { skip = 1 }
    skip && /^fi$/ { skip = 0; next }
    skip { next }
    { print }
  ' <<<"$TAIL")"
if [[ "$OLD_TAIL" == "$TAIL" ]] || ! bash -n <<<"$OLD_TAIL" 2>/dev/null; then
  unmeasurable "could not rebuild the pre-#114 tail block"
else
  CTRL="$( ( FAIL_COUNT=0; MAIL_DELIVERED=0; eval "$OLD_TAIL" ) >/dev/null 2>&1; echo $? )"
  [[ "$CTRL" -eq 0 ]] \
    || fail "negative control is broken: the pre-#114 tail exited $CTRL, not 0, so case 5 is not measuring what it claims"
fi

if [[ $rc -eq 0 ]]; then
  echo "PASS — undelivered report: MAIL_DELIVERED=0, mailer's words on stderr, /fail ping, exit 75"
  echo "       delivered report unchanged: success ping when clean, /fail on failing rows, exit 0"
  echo "       (negative controls: the pre-#114 ping and tail blocks both read as healthy)"
fi
exit $rc
