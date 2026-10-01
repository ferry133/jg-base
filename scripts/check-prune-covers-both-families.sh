#!/usr/bin/env bash
# Assert the off-site retention loop still recognises BOTH archive families.
#
# ferry133/jg-base#145 put a second family into the bucket prefix the DB
# backup's retention loop walks (`monitoring/backup/app/configmap.yaml`). That
# loop lists the whole prefix, pulls an 8-digit date out of each object name
# with sed, and deletes anything older than BACKUP_RETAIN_DAYS (default 30).
#
# So the claudecode archive's off-site lifetime is 30 days, decided by another
# app's knob and executed by another app's Job. That was nobody's decision --
# it is what the key shapes happen to produce. Written down and checked here
# rather than left implicit, because BOTH directions are silent:
#
#   - the key stops matching the extractor (a rename, a different stamp
#     format) -> `[ -n "$stamp" ] || continue` skips it, forever, and the
#     claudecode family accumulates with nothing saying so. ⚠️ This direction
#     is the reason the check exists: the keyring-bearing archive's off-site
#     lifetime going from 30 days to unbounded looks like nothing at all.
#   - the system key stops matching -> the DB archives stop being pruned.
#
# ⚠️ What this does NOT measure, stated because it is the same gap FO-runbook
# [5fe39a] flagged when raising this: the sed here is whatever sed THIS machine
# ships, and the Job runs busybox sed inside an alpine image. The expression is
# portable BRE (`\{8\}`), which is why the risk is considered low -- not
# because it was measured in the image. And no claudecode object has ever gone
# through that loop, because none exists yet.
#
# Usage: scripts/check-prune-covers-both-families.sh
#   exit 0 both families are recognised, 1 one is not, 2 cannot measure
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BK="$ROOT/kubernetes/apps/base/monitoring/backup/app/configmap.yaml"
AR="$ROOT/kubernetes/apps/base/claudecode/claude-code/im/enabled/state-archive-script.yaml"
for f in "$BK" "$AR"; do [[ -r "$f" ]] || { echo "cannot measure: $f not readable"; exit 2; }; done
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
yq -r '.data["backup.sh"]'  "$BK" > "$WORK/backup.sh"
yq -r '.data["archive.sh"]' "$AR" > "$WORK/archive.sh"
[[ -s "$WORK/backup.sh" && -s "$WORK/archive.sh" ]] || { echo "cannot measure: could not read both scripts out of the ConfigMaps"; exit 2; }

# The extractor, taken from the shipped loop rather than re-typed: a copy here
# would keep passing after the loop changed, which is the whole failure mode.
EXPR="$(sed -n "s/.*sed -n '\(s\/\.\*.*\)')\"\$/\1/p" "$WORK/backup.sh" | head -1)"
[[ -n "$EXPR" ]] || { echo "cannot measure: could not lift the stamp extractor out of backup.sh — the prune loop was rewritten, so this guard is reading nothing"; exit 2; }
grep -q '\[0-9\]' <<<"$EXPR" || { echo "cannot measure: the lifted expression has no digit class, so it is not the stamp extractor: ${EXPR}"; exit 2; }

# The key TEMPLATES, also lifted. Each uploader owns its own shape.
key_of() { sed -n 's/^KEY="\(.*\)"$/\1/p' "$1" | head -1; }
SYS_T="$(key_of "$WORK/backup.sh")"
CC_T="$(key_of "$WORK/archive.sh")"
[[ -n "$SYS_T" && -n "$CC_T" ]] || { echo "cannot measure: could not lift both KEY= templates (system='${SYS_T}' claudecode='${CC_T}')"; exit 2; }
[[ "$SYS_T" != "$CC_T" ]] || { echo "cannot measure: both uploaders report the same key template, so 'two families' cannot be tested: ${SYS_T}"; exit 2; }

CLUSTER_NAME="demo"; STAMP="20260930T190000Z"
render() { eval "printf '%s' \"$1\""; }          # the template's own ${…}
basename_of() { local k; k="$(render "$1")"; echo "${k##*/}"; }   # the loop sees `aws s3 ls` basenames

rc=0
fail() { echo "FAIL — $1"; rc=1; }
probe() { echo "$1" | sed -n "$EXPR"; }

for pair in "system:$SYS_T" "claudecode:$CC_T"; do
  fam="${pair%%:*}"; tmpl="${pair#*:}"
  name="$(basename_of "$tmpl")"
  got="$(probe "$name")"
  if [[ "$got" == "20260930" ]]; then
    printf 'ok    %-11s %-46s -> %s\n' "$fam" "$name" "$got"
  else
    fail "the retention loop pulls no usable date out of the ${fam} key '${name}' (got '${got:-<nothing>}'), so that family is never pruned — and an archive family that is never pruned is also an archive family nobody is told about"
  fi
done

# Negative control: a name with no stamp must yield nothing. Without this, an
# extractor that matched everything would read as full coverage.
ctl="$(probe "demo/demo-no-date-here.tar.gz.age")"
if [[ -n "$ctl" ]]; then
  echo "cannot measure: the extractor also produced '${ctl}' for a name with no 8-digit stamp, so matching proves nothing about either family"
  exit 2
fi

# Instrument control: break the extractor and both families must stop matching.
# A reader that cannot fail cannot certify.
broken="${EXPR//\[0-9\]/[A-Z]}"
[[ "$broken" != "$EXPR" ]] || { echo "cannot measure: could not mutate the extractor, so the readings above are unverified"; exit 2; }
if [[ -n "$(echo "$(basename_of "$SYS_T")" | sed -n "$broken")" ]]; then
  echo "cannot measure: the mutated extractor still matched the system key — this guard is not reading the expression it thinks it is"
  exit 2
fi

if [[ $rc -eq 0 ]]; then
  echo "PASS — the shipped retention loop recognises both families (30-day default applies to the claudecode archive too; see the notes in both ConfigMaps)"
  echo "       ⚠️ measured with this machine's sed, not the image's busybox, and no claudecode object has ever been through the loop"
fi
exit $rc
