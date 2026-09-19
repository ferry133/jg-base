#!/usr/bin/env bash
# Assert that daily-check refuses to report success on a cluster it was never
# configured for, and that a configured cluster's exit status is unaffected.
#
# ferry133/jg-base#112 (routed from fleet-ops#13, opened by FO-handler
# [f92b04]): the unconfigured branch printed an honest message and then
# `exit 0`, so the Job read `Complete 1/1`. The only watcher's ABSENCE looked
# exactly like a healthy cluster. jg-jcc1 ran from creation to discovery with
# zero successful off-site backups while three layers stayed quiet; this was
# the outermost of them.
#
# Why the exit status and not a new status object: on an unconfigured cluster
# BOTH outward channels are gated on the same operator action — the email on
# DAILY_CHECK_SMTP_{USERNAME,PASSWORD,FROM} + _NOTIFY_EMAIL_TO, the dead-man on
# DAILY_CHECK_HEALTHCHECKS_PING_URL, all five one `default('')` apart in
# jg-cluster-template. Such a cluster was never registered on healthchecks.io,
# so nothing there could go red. Two defences sharing a premise are one
# defence. The Job's exit status is the only channel that needs neither a
# cluster.yaml value nor extra RBAC.
#
# The half that is easy to lose later, and is case 8 below: row-level failures
# must STILL exit 0. Making the Job red for a failing row would put the
# unconfigured cluster and the broken cluster in the same bucket, and would
# re-create #6 — a check that fires on every run gets switched off.
#
# Sources the real branch out of the ConfigMap rather than restating it: a copy
# here would drift, and the copy that drifts keeps passing.
#
# ⚠️ THIS FILE ALONE DOES NOT SECURE THE THREE EXIT CODES. It pins 78 for an
# unconfigured cluster; `check-mail-failure-is-visible.sh` pins 75 for a report
# that was not delivered. Swapping the two constants is caught only by the
# corresponding file, so the pair is what makes 0/75/78 distinguishable rather
# than merely "non-zero" (measured by FO-handler [f92b04] as mutations M1/M2 on
# #115). Whoever deletes one of these should know what they are deleting.
#
# Usage: scripts/check-unconfigured-exits-nonzero.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "cannot measure: awk is missing"; exit 2; }

# Extract the guard by its opening `if` and the `fi` at the same indent. The
# anchor deliberately contains no part of what the mutation below changes: if
# the anchor moved with the constant, flipping the constant would make this
# script report "cannot measure" instead of failing, and a red that reads as
# "cannot measure" is how #108 stayed invisible for 8 days.
extract() {
  awk '
    /^[[:space:]]*if \[\[ -z "\$\{SMTP_USERNAME:-\}"/ { ind = match($0, /[^ ]/); grabbing = 1 }
    grabbing { print }
    grabbing && /^[[:space:]]*fi[[:space:]]*$/ && match($0, /[^ ]/) == ind { exit }
  ' "$1" | sed 's/^    //'
}

BLOCK="$(extract "$CM")"
[[ -n "$BLOCK" ]] || { echo "cannot measure: the SMTP_USERNAME guard was not found in the ConfigMap"; exit 2; }
# Anchor on the message, not on any of the four conditions: anchoring on a
# condition made removing that condition read as "cannot measure" instead of
# as the failure it is (caught by mutation C while writing this).
grep -q 'daily-check is not configured' <<<"$BLOCK" || { echo "cannot measure: extracted block is not the guard"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# Run one env combination against a block and print its exit status. Each case
# gets a fresh subshell, so no variable leaks into the next — that leak is what
# made check-image-pin-row.sh agree with itself across cases before #109.
probe() {
  local blk="$1" cluster="$2" u="$3" p="$4" f="$5" t="$6"
  (
    CLUSTER_NAME="$cluster"
    [[ "$u" == UNSET ]] && unset SMTP_USERNAME     || SMTP_USERNAME="$u"
    [[ "$p" == UNSET ]] && unset SMTP_PASSWORD     || SMTP_PASSWORD="$p"
    [[ "$f" == UNSET ]] && unset SMTP_FROM         || SMTP_FROM="$f"
    [[ "$t" == UNSET ]] && unset NOTIFY_EMAIL_TO   || NOTIFY_EMAIL_TO="$t"
    eval "$blk"
  ) >/dev/null 2>&1
  echo $?
}

# ---------------------------------------------------------------- the defect
# 1-5. Every way of being unconfigured must leave a non-zero status behind.
for case in "empty username::::demo@x::from@x::to@x" \
            "empty password::u::::from@x::to@x" \
            "empty from::u::p::::to@x" \
            "empty recipient::u::p::from@x::" \
            "unset username::UNSET::p::from@x::to@x"; do
  name="${case%%::*}"; rest="${case#*::}"
  IFS='::' read -r _ _ _ _ <<<"" 2>/dev/null   # no-op; keeps shellcheck quiet
  u="$(cut -d'|' -f1 <<<"${rest//::/|}")"
  p="$(cut -d'|' -f2 <<<"${rest//::/|}")"
  f="$(cut -d'|' -f3 <<<"${rest//::/|}")"
  t="$(cut -d'|' -f4 <<<"${rest//::/|}")"
  got="$(probe "$BLOCK" demo "$u" "$p" "$f" "$t")"
  [[ "$got" -ne 0 ]] \
    || fail "$name: an unconfigured cluster exited 0 — #112 has regressed, the Job would read Complete"
  [[ "$got" -eq 78 ]] \
    || fail "$name: exited $got, expected 78 (sysexits EX_CONFIG) — a bare 1 cannot be told apart from a crash under set -u"
done

# 6. Positive control for the OTHER direction: a fully configured cluster must
#    fall through this guard untouched. Without this, "always exit non-zero"
#    would pass every case above.
got="$(probe "$BLOCK" demo u p from@x to@x)"
[[ "$got" -eq 0 ]] \
  || fail "a fully configured cluster exited $got at the guard — every cluster's Job would now be Failed"

# 7. The message has to name the cluster and reach stderr: on an unconfigured
#    cluster the log is the only place the reason exists.
MSG="$(
  (
    CLUSTER_NAME=sentinel-cluster SMTP_USERNAME="" SMTP_PASSWORD=p SMTP_FROM=f NOTIFY_EMAIL_TO=t
    eval "$BLOCK"
  ) 2>&1 >/dev/null
)"
grep -q 'sentinel-cluster' <<<"$MSG" \
  || fail "the message did not reach stderr, or does not name the cluster: ${MSG:-<empty>}"
grep -q 'daily_check_smtp_username' <<<"$MSG" \
  || fail "the message no longer names the fields to fill in"

# 8. A configured run whose report was DELIVERED still exits 0, even with rows
#    failing. This used to be a grep for `exit 0` near the end-of-run line;
#    #114 made the tail conditional, and the grep then reported '<none>' — a
#    structural assertion that stops being able to read the thing it guards.
#    Running the tail is the same question asked so that it keeps working.
TAIL="$(awk '
    /^[[:space:]]*echo "==> Done\./ { grabbing = 1 }
    grabbing && /^[^[:space:]]/       { exit }
    grabbing                          { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$TAIL" ]] || { echo "cannot measure: the end-of-run block was not found"; exit 2; }
bash -n <<<"$TAIL" || { echo "cannot measure: end-of-run block does not parse"; exit 2; }

tail_exit() { ( FAIL_COUNT="$1"; MAIL_DELIVERED="$2"; eval "$TAIL" ) >/dev/null 2>&1; echo $?; }

got="$(tail_exit 3 1)"
[[ "$got" -eq 0 ]] \
  || fail "a configured run with 3 failing rows and the report delivered exited $got, not 0 — Job status has become a second copy of cluster health and #6 would repeat"
got="$(tail_exit 0 1)"
[[ "$got" -eq 0 ]] \
  || fail "a clean configured run exited $got, not 0"

# --------------------------------------------------- can this script fail?
# Rebuild the pre-#112 block (the only change: the constant) and assert that
# case 1 catches it. A guard that cannot fail reads exactly like one that
# passes — this is the case that proves it discriminates.
# `unmeasurable` rather than a bare `exit 2`: when an assertion above has
# already failed, that red must win. Reporting a live regression as "cannot
# measure" is the #108 shape — and this script did exactly that until the
# mutation run below caught it.
unmeasurable() { if [[ $rc -eq 0 ]]; then echo "cannot measure: $1"; exit 2; else echo "note: $1 (an assertion already failed, reporting that)"; fi; }

OLD_BLOCK="$(sed -E 's/^([[:space:]]*)exit 78[[:space:]]*$/\1exit 0/' <<<"$BLOCK")"
if [[ "$OLD_BLOCK" == "$BLOCK" ]]; then
  unmeasurable "could not rebuild the pre-#112 block — the exit line did not match"
elif ! bash -n <<<"$OLD_BLOCK" 2>/dev/null; then
  unmeasurable "rebuilt pre-#112 block does not parse"
else
  CTRL="$(probe "$OLD_BLOCK" demo "" p from@x to@x)"
  [[ "$CTRL" -eq 0 ]] \
    || fail "negative control is broken: the pre-#112 block exited $CTRL, so this script is not measuring what it claims"
fi

if [[ $rc -eq 0 ]]; then
  echo "PASS — unconfigured exits 78, configured falls through, configured runs still end exit 0"
  echo "       (negative control: the pre-#112 block exits 0 and case 1 catches it)"
fi
exit $rc
