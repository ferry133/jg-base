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
#   - the key moves to a SUB-PREFIX. The loop lists non-recursively, so a
#     sub-prefix arrives as one `PRE <name>/` line whose `$4` is empty ->
#     `continue`, same outcome, and the object names are never seen at all.
#
# ⚠️ That third one was this guard's own blind spot, and it was blind in
# exactly the direction the two paragraphs above promise to cover: the first
# version compared BASENAMES, so "the key moved" and "the key did not move"
# produced identical readings (ferry133/jg-base#147, found by FO-runbook
# [5fe39a] while re-verifying #146 — their P3 returned rc=0 while P1/P2
# returned 1, so the instrument was alive and the gap was real).
#
# The fix is not "also compare prefixes": two families moved TOGETHER into
# `<cluster>/sub/` keep equal prefixes and both vanish from the loop. What is
# asserted instead is the actual contract -- each rendered key sits DIRECTLY
# under the prefix the shipped loop lists, which is lifted from the loop
# rather than assumed.
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

# The PREFIX the loop actually lists, lifted from the same line, plus whether
# it lists recursively -- because the whole basename model below depends on it.
LS_LINE="$(grep -m1 'aws s3 ls' "$WORK/backup.sh")"
[[ -n "$LS_LINE" ]] || { echo "cannot measure: the prune loop has no 'aws s3 ls' line — it was rewritten, so this guard does not know what it lists"; exit 2; }
if grep -q -- '--recursive' <<<"$LS_LINE"; then
  # Deliberately not a second code path: a recursive listing makes sub-prefixes
  # visible and invalidates the basename reasoning this whole script is built
  # on. An unexercised branch that silently reads as coverage is worse than a
  # loud stop, so this stops.
  echo "cannot measure: the prune loop now lists with --recursive, which changes what it can see — this guard models a NON-recursive listing and must be rewritten before it means anything"
  exit 2
fi
LS_URL="$(sed -n 's/.*"\(s3:\/\/[^"]*\)".*/\1/p' <<<"$LS_LINE")"
[[ -n "$LS_URL" ]] || { echo "cannot measure: could not lift the listed s3 URL out of '${LS_LINE}'"; exit 2; }
# `s3://${BACKUP_R2_BUCKET}/${CLUSTER_NAME}/` -> the key prefix `${CLUSTER_NAME}/`
LS_PREFIX_T="${LS_URL#s3://\$\{BACKUP_R2_BUCKET\}/}"
[[ "$LS_PREFIX_T" != "$LS_URL" ]] || { echo "cannot measure: the listed URL '${LS_URL}' is not of the form s3://\${BACKUP_R2_BUCKET}/<prefix>, so the prefix cannot be isolated"; exit 2; }

# The key TEMPLATES, also lifted. Each uploader owns its own shape.
# ⚠️ Exactly one per script, asserted. The first version ended in `head -1`,
# which would have measured the wrong assignment in silence had either script
# ever gained a second one (FO-runbook [5fe39a], #147).
key_of() {
  local n; n="$(grep -c '^KEY=' "$1")"
  [[ "$n" == "1" ]] || { echo "cannot measure: $(basename "$1") has ${n} top-level KEY= assignments, so 'the key' is ambiguous" >&2; return 1; }
  sed -n 's/^KEY="\(.*\)"$/\1/p' "$1"
}
SYS_T="$(key_of "$WORK/backup.sh")" || exit 2
CC_T="$(key_of "$WORK/archive.sh")" || exit 2
[[ -n "$SYS_T" && -n "$CC_T" ]] || { echo "cannot measure: could not lift both KEY= templates (system='${SYS_T}' claudecode='${CC_T}')"; exit 2; }
[[ "$SYS_T" != "$CC_T" ]] || { echo "cannot measure: both uploaders report the same key template, so 'two families' cannot be tested: ${SYS_T}"; exit 2; }

CLUSTER_NAME="demo"; STAMP="20260930T190000Z"
render() { eval "printf '%s' \"$1\""; }          # the template's own ${…}
basename_of() { local k; k="$(render "$1")"; echo "${k##*/}"; }   # the loop sees `aws s3 ls` basenames

rc=0
fail() { echo "FAIL — $1"; rc=1; }
probe() { echo "$1" | sed -n "$EXPR"; }

LS_PREFIX="$(render "$LS_PREFIX_T")"
echo "the loop lists: ${LS_PREFIX} (non-recursive)"

# ⚠️ ONE function, called by the real loop AND by its controls below.
#
# The first version inlined the comparison in the loop and the control
# RE-WROTE it inside a subshell, so the control never executed the line it
# claimed to protect: FO-runbook [5fe39a] replaced the real comparison with
# `if false` and got rc=0 on a clean tree AND rc=0 on a broken one. The
# script's own promise ("a future rewrite that drops the placement check is
# caught here") was false, and placement is the only assertion covering "both
# families moved together".
#
# Third instance of this shape in one day: a control that re-implements its
# subject tests the re-implementation. The structural answer is that there is
# only one copy to test.
PLACED=0            # how many families the loop actually examined
check_family() {    # <family> <key template>  -> 0 ok, 1 reported a failure
  local fam="$1" tmpl="$2" key name got
  key="$(render "$tmpl")"
  name="${key##*/}"
  PLACED=$((PLACED + 1))

  # PLACEMENT first. A key one level deeper is not a key the loop ever reads:
  # a non-recursive listing collapses it into a single `PRE <name>/` row whose
  # `$4` is empty, so the stamp check below would be asking about a name the
  # loop never sees -- and it would pass.
  if [[ "$key" != "${LS_PREFIX}${name}" ]]; then
    echo "FAIL — the ${fam} key renders to '${key}', which is not directly under the prefix the loop lists ('${LS_PREFIX}') — a non-recursive listing turns a deeper key into one 'PRE <name>/' row with an empty \$4, so that family is never pruned and nothing says so"
    return 1
  fi

  got="$(probe "$name")"
  if [[ "$got" == "20260930" ]]; then
    printf 'ok    %-11s %-46s -> %s\n' "$fam" "$name" "$got"
    return 0
  fi
  echo "FAIL — the retention loop pulls no usable date out of the ${fam} key '${name}' (got '${got:-<nothing>}'), so that family is never pruned — and an archive family that is never pruned is also an archive family nobody is told about"
  return 1
}

PLACE_FAILS=0
for pair in "system:$SYS_T" "claudecode:$CC_T"; do
  check_family "${pair%%:*}" "${pair#*:}" || { rc=1; PLACE_FAILS=$((PLACE_FAILS + 1)); }
done

# The call site is part of what must not vanish: a loop that stops calling
# check_family leaves the controls below passing and nothing measured.
if [[ "$PLACED" != "2" ]]; then
  echo "cannot measure: the loop examined ${PLACED} families, not 2 — the readings above do not cover both"
  exit 2
fi

# Secondary: the two families must share one prefix. Kept because #147 asked
# for it by name, and because it is the assertion that fires when the two keys
# disagree with EACH OTHER rather than with the listed prefix — measured by
# FO-runbook [5fe39a] to be the one that catches a single-family move (P3),
# while placement is what catches both moving together (P3c). Two halves, not
# one assertion with a spare.
if [[ "${SYS_T%/*}" != "${CC_T%/*}" ]]; then
  fail "the two uploaders no longer write to the same prefix (system '${SYS_T%/*}', claudecode '${CC_T%/*}') — one retention loop cannot reach two prefixes"
fi

# ⚠️ Both families failing placement while still AGREEING with each other has
# TWO causes, and this guard cannot tell them apart from the manifests: the
# keys moved and the loop did not, or the loop's listed prefix moved and the
# keys did not. Said as two, because naming one points the reader the wrong way
# half the time. My earlier claim that this case "fails with a different
# sentence" was wrong — FO-runbook measured P6 printing the same sentence as
# P3c. Either cause leaves the family unpruned, so the verdict is the same and
# only the explanation is ambiguous.
if [[ "$PLACE_FAILS" == "2" && "${SYS_T%/*}" == "${CC_T%/*}" ]]; then
  echo "       ↳ both families disagree with the listed prefix while still agreeing with each other. Either the keys moved (and the loop still lists '${LS_PREFIX}'), or the loop's listed prefix moved (and the keys still sit under '$(render "${SYS_T%/*}")/'). Not decidable from the manifests alone; both leave the family unpruned."
fi

# --- controls ---------------------------------------------------------------
# ⚠️ A control may only say "cannot measure" while nothing has already FAILED.
#
# C3b's premise is that the shipped tree is correct; once a case has failed
# that premise is gone, so a failing C3b is the expected consequence of the
# defect rather than a doubt about the instrument. The first version called
# `exit 2` inline and four genuine failures (P3, P2, P6, P3c) came back as
# "cannot measure" with their FAIL lines printed above the wrong exit code.
#
# ⚠️ FOURTH time today I have written this bug — twice found and fixed in other
# guards hours earlier, then written fresh here. Knowing the rule is not the
# same as applying it, so it is now written where the next person edits this
# block rather than only in a commit message: notes accumulate, a real failure
# outranks every one of them.
CTL_NOTE=""
unmeasurable() { CTL_NOTE="${CTL_NOTE}${CTL_NOTE:+
}cannot measure: $1"; }

# Negative control: a name with no stamp must yield nothing. Without this, an
# extractor that matched everything would read as full coverage.
ctl="$(probe "demo/demo-no-date-here.tar.gz.age")"
[[ -z "$ctl" ]] || unmeasurable "the extractor also produced '${ctl}' for a name with no 8-digit stamp, so matching proves nothing about either family"

# C3 / C3b — both polarities, through the SAME check_family the loop uses, so
# breaking that function or its comparison shows up here. C3 reconstructs
# #147's P3 from the lifted template rather than from a hand-written copy.
_p=$PLACED
if check_family claudecode "${LS_PREFIX_T}sub/\${CLUSTER_NAME}-claudecode-\${STAMP}.tar.gz.age" >/dev/null 2>&1; then
  unmeasurable "a claudecode key moved into a sub-prefix did NOT trip the placement check — that check is doing nothing, and #147 would still be open"
fi
if ! check_family claudecode "$CC_T" >/dev/null 2>&1; then
  # Only meaningful on an otherwise-clean tree; see the note at the top.
  [[ $rc -eq 0 ]] && unmeasurable "the real claudecode key did NOT satisfy the placement check either, so C3 above rejects everything and proves nothing"
fi
PLACED=$_p   # the controls must not inflate the loop's own count
[[ -n "$CTL_NOTE" ]] || echo "control: the placement check accepts the shipped key and rejects the same key one level deeper — both through the loop's own function, not a copy of it"

# Instrument control: break the extractor and both families must stop matching.
# A reader that cannot fail cannot certify.
broken="${EXPR//\[0-9\]/[A-Z]}"
if [[ "$broken" == "$EXPR" ]]; then
  unmeasurable "could not mutate the extractor, so the stamp readings above are unverified"
elif [[ -n "$(probe_with() { echo "$1" | sed -n "$broken"; }; probe_with "$(render "${SYS_T##*/}")")" ]]; then
  unmeasurable "the mutated extractor still matched the system key — this guard is not reading the expression it thinks it is"
fi

if [[ $rc -ne 0 ]]; then
  [[ -n "$CTL_NOTE" ]] && echo "note: a control could not run either (expected when a case has failed) — ${CTL_NOTE//cannot measure: /}"
  exit 1
fi
if [[ -n "$CTL_NOTE" ]]; then
  echo "$CTL_NOTE"
  exit 2
fi
echo "PASS — both families sit directly under the prefix the shipped loop lists, and both yield a date to its extractor (so the 30-day default applies to the claudecode archive too; see the notes in both ConfigMaps)"
echo "       ⚠️ measured with this machine's sed, not the image's busybox; no claudecode object has ever been through the loop; and the 'PRE <name>/' shape a sub-prefix produces is read from the AWS CLI's documented non-recursive output, not observed in-cluster"
exit 0