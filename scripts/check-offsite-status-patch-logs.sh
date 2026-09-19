#!/usr/bin/env bash
# Assert that offsite-backup's post-upload status patch leaves a trace on BOTH
# paths, so "the patch ran and succeeded" and "the patch never ran" stop being
# the same thing in the log.
#
# ferry133/jg-base#117: the patch spoke only when it FAILED. A successful run
# therefore printed one status line where the server had recorded two writes
# (`--show-managed-fields`: kubectl-client-side-apply at publish, kubectl-patch
# after the upload). The log is what people read, and it said the opposite of
# what happened.
#
# The cost is already paid: from `grep -c "published status" = 1`,
# ferry133/fleet-ops#13 concluded the status table was still written BEFORE the
# upload, that `uploaded=yes` was a prediction rather than a reading, and that
# ferry133/jg-base#63 had been closed without being fixed. All wrong, all
# retracted. The log could not have told anyone otherwise.
#
# ⚠️ NOT asserted here, deliberately: the exact wording of the FIRST status
# line (`published status: configmap/offsite-backup-status`). fleet-ops greps
# that string, so it is an interface; this guard pins that a second line exists
# and where it sits, not how either is phrased beyond the marker each carries.
#
# Sources the real upload block out of the ConfigMap rather than restating it:
# a copy here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-offsite-status-patch-logs.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/backup/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "cannot measure: awk is missing"; exit 2; }

# Anchored on the `aws s3 cp` line and the `fi` at the same indent. Neither
# anchor contains anything the mutations below change: an anchor that moves
# with the code under test turns a real regression into "cannot measure".
BLOCK="$(awk '
    /^[[:space:]]*if aws s3 cp --endpoint-url/ { ind = match($0, /[^ ]/); grabbing = 1 }
    grabbing { print }
    grabbing && /^[[:space:]]*fi[[:space:]]*$/ && match($0, /[^ ]/) == ind { exit }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: the upload block was not found in the ConfigMap"; exit 2; }
grep -q 'offsite-backup-status' <<<"$BLOCK" || { echo "cannot measure: extracted block is not the upload block"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# One run of the block. `up` = whether the upload succeeds, `pat` = whether the
# patch succeeds. Every case is its own subshell, so nothing leaks forward.
run() {
  local up="$1" pat="$2" blk="${3:-$BLOCK}"
  (
    BACKUP_R2_ENDPOINT=https://s3.example BACKUP_R2_BUCKET=demo-backup
    CLUSTER_NAME=demo STAMP=20260919T000000Z ARCHIVE=/tmp/demo.tar.gz
    KEY="${CLUSTER_NAME}/x.tar.gz.age"
    log() { echo "$*"; }
    aws()     { [[ "$up"  == ok ]]; }
    kubectl() { [[ "$pat" == ok ]]; }
    eval "$blk"
  ) 2>&1
}

SUCCESS_MARK='status patched'
UPLOAD_MARK='uploaded s3://'

# ------------------------------------------------------------------ the defect
# 1. A successful patch must say so. This is the case that was silent.
out="$(run ok ok)"
grep -q "$SUCCESS_MARK" <<<"$out" \
  || fail "a SUCCESSFUL status patch printed nothing — #117 has regressed, and the log again shows one write where the server records two. Log was: $(tr '\n' '|' <<<"$out")"

# 2. It must come AFTER the upload line, or it does not evidence the ordering
#    that fleet-ops#13 got wrong.
u="$(grep -n "$UPLOAD_MARK" <<<"$out" | head -1 | cut -d: -f1)"
s="$(grep -n "$SUCCESS_MARK" <<<"$out" | head -1 | cut -d: -f1)"
if [[ -z "$u" || -z "$s" ]]; then
  fail "could not locate both the upload line and the status line in a successful run: $(tr '\n' '|' <<<"$out")"
elif [[ "$s" -le "$u" ]]; then
  fail "the status line (line $s) is not after the upload line (line $u) — the log still cannot show that the patch follows the upload"
fi

# 3. A FAILED patch must warn and must NOT claim success. Both halves: a branch
#    that prints the success line on every path would satisfy case 1 alone.
out="$(run ok fail)"
grep -q 'WARNING' <<<"$out" || fail "a failed status patch printed no WARNING: $(tr '\n' '|' <<<"$out")"
grep -q "$SUCCESS_MARK" <<<"$out" \
  && fail "a FAILED status patch still printed the success line — the two outcomes are indistinguishable again, which is the whole of #117"

# 4. A failed UPLOAD reaches neither: it must be FATAL and must not touch the
#    status at all.
out="$(run fail ok)"
grep -q 'FATAL' <<<"$out" || fail "a failed upload did not print FATAL: $(tr '\n' '|' <<<"$out")"
grep -q "$SUCCESS_MARK" <<<"$out" \
  && fail "a failed upload still printed the status line — the table would claim an upload that never happened"

# 5. Positive control on the OTHER line: the first status write still speaks.
#    Pinned by marker only, not by wording — fleet-ops greps that string.
grep -q 'published status' "$CM" \
  || fail "the first status write no longer logs anything — with it gone there is nothing for the second line to be second to"

# --------------------------------------------------- can this script fail?
unmeasurable() { if [[ $rc -eq 0 ]]; then echo "cannot measure: $1"; exit 2; else echo "note: $1 (an assertion already failed, reporting that)"; fi; }

# Rebuild the pre-#117 block: the patch speaks only on failure.
OLD="$(awk '
    /if kubectl -n monitoring patch/ { print "      kubectl -n monitoring patch configmap offsite-backup-status \\"; skip = 1; next }
    skip && /--type merge/ { print "        --type merge -p '"'"'{\"data\":{\"uploaded\":\"yes\"}}'"'"' >/dev/null 2>&1 \\"; next }
    skip && /status patched/ { next }
    skip && /^[[:space:]]*else[[:space:]]*$/ { next }
    skip && /could not mark status/ { print "        || log \"WARNING: could not mark status uploaded=yes\""; next }
    skip && /^[[:space:]]*fi[[:space:]]*$/ { skip = 0; next }
    { print }
  ' <<<"$BLOCK")"
if [[ "$OLD" == "$BLOCK" ]] || ! bash -n <<<"$OLD" 2>/dev/null; then
  unmeasurable "could not rebuild the pre-#117 block"
else
  ctrl="$(run ok ok "$OLD")"
  if grep -q "$SUCCESS_MARK" <<<"$ctrl"; then
    fail "negative control is broken: the pre-#117 block printed a success line, so case 1 is not measuring what it claims"
  elif ! grep -q "$UPLOAD_MARK" <<<"$ctrl"; then
    unmeasurable "the rebuilt pre-#117 block did not even reach the upload line"
  fi
fi

if [[ $rc -eq 0 ]]; then
  echo "PASS — the status patch speaks on success (after the upload line) and on failure, and on neither when the upload itself fails"
  echo "       (negative control: the pre-#117 block is silent on success and case 1 catches it)"
fi
exit $rc
