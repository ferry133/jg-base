#!/usr/bin/env bash
# Assert that offsite-backup's Job cannot run forever, and that the bound is
# above the slowest run anyone has actually measured.
#
# ferry133/jg-base#126: the CronJob had no `activeDeadlineSeconds` at all while
# carrying `concurrencyPolicy: Forbid`. A stuck run therefore blocks every
# later schedule, and none of the three things you would look at says so:
#
#   * the stuck Job stays `Running`, so nothing is red
#   * `startingDeadlineSeconds: 3600` stops counting missed starts after an hour
#   * daily-check rows 19/21 warn at 26h and fail at 48h — a day late
#
# That is not hypothetical: #124 measured this very Job spending 11 minutes
# inside `apk add` on a ~100 KB/s node. How long it stalls when the package
# mirror is unreachable has never been measured by anyone.
#
# ⚠️ What this does NOT assert, on purpose:
#   * `concurrencyPolicy: Forbid`. It is why the deadline matters, but
#     switching to `Replace` would ALSO stop a stuck run from blocking the
#     schedule. Asserting it would fire on a different correct fix, and a
#     guard that fires on correct code is the one that gets switched off.
#   * the exact value 3600. What is asserted is that a bound exists and clears
#     the measured worst case; how much headroom beyond that is judgement.
#
# Usage: scripts/check-backup-has-a-deadline.sh
#   exit 0 the bound is present and sane, 1 it is not, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CJ="$ROOT/kubernetes/apps/base/monitoring/backup/app/cronjob.yaml"
[[ -r "$CJ" ]] || { echo "cannot measure: $CJ not readable"; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }

# 13m27s on the slow appliance, 2026-09-20, measured by FO-openspec [8e8ef1]
# and recorded on #124: Job 17:31:48 -> 17:45:15. A healthy run, not a stuck
# one. The bound has to clear this or it kills backups that would have worked.
SLOWEST_HEALTHY_RUN=807

N="$(yq -r 'select(.kind == "CronJob") | .metadata.name' "$CJ" | grep -c . || true)"
[[ "$N" == "1" ]] || { echo "cannot measure: expected exactly one CronJob in $CJ, found ${N}"; exit 2; }

DEADLINE="$(yq -r 'select(.kind == "CronJob") | .spec.jobTemplate.spec.activeDeadlineSeconds // "null"' "$CJ")"

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# --- 1. it must exist. This is the regression.
if [[ "$DEADLINE" == "null" || -z "$DEADLINE" ]]; then
  fail "the offsite-backup Job has no activeDeadlineSeconds — with concurrencyPolicy Forbid, one stuck run blocks every later schedule while staying Running, and the only signal is daily-check a day later (#126)"
elif ! [[ "$DEADLINE" =~ ^[0-9]+$ ]]; then
  fail "activeDeadlineSeconds is '${DEADLINE}', not a number of seconds"
else
  # --- 2. and it must clear the slowest HEALTHY run anyone has measured.
  #     Without this, "there is a number" and "there is a correct number" are
  #     the same reading — and a too-small number turns slow into no-backup,
  #     which is worse than what it guards against.
  if [[ "$DEADLINE" -le "$SLOWEST_HEALTHY_RUN" ]]; then
    fail "activeDeadlineSeconds is ${DEADLINE}s, at or below the slowest run measured to SUCCEED (${SLOWEST_HEALTHY_RUN}s, #124) — this kills backups that would have worked, which is worse than the stall it is meant to bound"
  fi
fi

# --- 3. positive control on the reader itself: a field known to be present
#     must come back. Without it a yq path typo returns null for everything
#     and case 1 fires with a message about a defect that does not exist.
TTL="$(yq -r 'select(.kind == "CronJob") | .spec.jobTemplate.spec.ttlSecondsAfterFinished // "null"' "$CJ")"
[[ "$TTL" =~ ^[0-9]+$ ]] \
  || { echo "cannot measure: the reader could not see ttlSecondsAfterFinished either, so a null above says nothing about activeDeadlineSeconds"; exit 2; }

if [[ $rc -eq 0 ]]; then
  echo "PASS — activeDeadlineSeconds=${DEADLINE}s, above the ${SLOWEST_HEALTHY_RUN}s slowest measured healthy run"
  echo "       (reader control: ttlSecondsAfterFinished=${TTL} read back from the same path;"
  echo "        concurrencyPolicy and the exact value are deliberately not asserted — see the header)"
fi
exit $rc
