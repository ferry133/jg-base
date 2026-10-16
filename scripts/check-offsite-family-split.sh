#!/usr/bin/env bash
# Assert row 21 answers for the SYSTEM backup family, and that the claudecode
# family never goes quiet.
#
# ferry133/jg-base#145 put a second archive family into the same bucket prefix
# the daily check watches (`<cluster>/<cluster>-claudecode-<stamp>.tar.gz.age`
# beside `<cluster>/<cluster>-<stamp>.tar.gz.age`). The two upload on separate
# schedules from separate Jobs, so they do not fail together -- and row 21 used
# to take the newest object in the prefix, full stop.
#
# That is the whole defect: `offsite-backup` dead for three days, claudecode
# still uploading nightly, and the row reports a fresh destination. Not a
# missing check -- a check that moved onto a different subject while keeping
# its old name, which is the one failure mode nobody re-reads.
#
# Found by FO-runbook [5fe39a] during acceptance of #146, and the ordering is
# part of it: the fix has to land NO LATER than the first claudecode upload,
# because after that the masking is live on every cluster.
#
# The second half matters as much: scoping the row to the system family could
# silently drop claudecode from the report, and "we stopped looking" is the
# same green as "it is fine". So every outcome here must still name it.
#
# Usage: scripts/check-offsite-family-split.sh
#   exit 0 the row is family-correct, 1 it is not, 2 cannot measure
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cannot measure: jq is missing — the row's selector IS a jq expression, so a shell approximation would be testing something else"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "cannot measure: python3 is missing (needed to turn fixture timestamps into epochs)"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
yq -r '.data."run-check.sh"' "$CM" > "$WORK/run-check.sh" 2>/dev/null
[[ -s "$WORK/run-check.sh" ]] || { echo "cannot measure: could not read data['run-check.sh'] out of $CM"; exit 2; }
bash -n "$WORK/run-check.sh" || { echo "cannot measure: run-check.sh does not parse"; exit 2; }

# Slice row 21. A miss must abort: an empty block emits no row at all, and
# "no row" would quietly satisfy nothing while reading as a clean run.
python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
w = Path(sys.argv[1]); s = (w / "run-check.sh").read_text()
try:
    blk = s[s.index("# 21. Off-site backup destination"):s.index("# 22. Stalled provisioning tickets")]
except ValueError:
    sys.exit("could not locate row 21 — the section markers moved")
for token, why in (("list-objects-v2", "it never lists the destination"),
                   ("-claudecode-", "it has no family selector at all"),
                   ("record fail", "it cannot emit fail")):
    if token not in blk:
        sys.exit("located a block, but %s — wrong slice" % why)
(w / "block.sh").write_text(blk)
PY
[[ -s "$WORK/block.sh" ]] || { echo "cannot measure: row 21 could not be sliced"; exit 2; }

NOW=1767225600   # fixed "now": ages are arithmetic, not wall-clock

mkfix() { # mkfix <cluster> <system age h|-> <claudecode age h|->   (+ $XA, see below)
  python3 - "$NOW" "$1" "$2" "$3" "${XA:--}" <<'PY'
import sys, json, datetime
now, cn, sysage, ccage, xage = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
def ts(h):
    if h == "bad": return "not-a-time"
    t = datetime.datetime.fromtimestamp(now - int(h) * 3600, datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S+00:00")
# Keys built from the cluster name the way the two uploaders build them
# (monitoring/backup backup.sh, claudecode archive.sh), so a cluster name
# containing "-claudecode-" produces the colliding shape for real instead of
# being asserted about.
c = []
if sysage != "-": c.append({"Key": "%s/%s-20260930T190000Z.tar.gz.age" % (cn, cn), "LastModified": ts(sysage)})
if ccage  != "-": c.append({"Key": "%s/%s-claudecode-20261001T190000Z.tar.gz.age" % (cn, cn), "LastModified": ts(ccage)})
# An EXTRA instance's archive (archive.sh with ARCHIVE_INSTANCE=cc,
# jg-cluster-template#202): same prefix, instance name before the stamp.
if xage   != "-": c.append({"Key": "%s/%s-claudecode-cc-20261002T190000Z.tar.gz.age" % (cn, cn), "LastModified": ts(xage)})
print(json.dumps({"Contents": c} if c else {"RequestCharged": None}))
PY
}

FAILED=0
run() { # run <block> <label> <cluster> <sysage> <ccage> <want-level> <needle>...
  local blk="$1" label="$2" cn="$3" sysage="$4" ccage="$5" want="$6"; shift 6
  local fixture; fixture="$(mkfix "$cn" "$sysage" "$ccage")"
  OUT=""
  CLUSTER_NAME="$cn"; BACKUP_R2_BUCKET="demo-backup"
  BACKUP_R2_ENDPOINT="https://minio.example.cc"
  BACKUP_R2_ACCESS_KEY_ID="AKIA"; BACKUP_R2_SECRET_ACCESS_KEY="s3cr3t"
  record() { OUT="[$1] $2${3:+ — $3}"; }
  date() { if [[ "$*" == "-u +%s" ]]; then echo "$NOW"; else command date "$@"; fi; }
  # Parses its ARGUMENT. A stub that ignores it would return one age for both
  # families, and then every case here would pass whatever the selector did.
  epoch_of() { python3 -c "import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%S%z').timestamp()))" "${1/Z/+00:00}" 2>/dev/null; }
  aws() { printf '%s\n' "$fixture"; }
  # The archive CronJob as the row reads it (#152). CJ is set per case:
  #   on:<h>   present, not suspended, created <h> hours before NOW
  #   suspended / off (NotFound) / err (any other error: the third outcome)
  # It checks its ARGUMENTS, so a row that asks about the wrong object reads
  # `err` here instead of passing on whatever the stub happens to say.
  kubectl() {
    [[ "$*" == "-n claudecode get cronjob claudecode-state-backup -o json" ]] \
      || { echo "stub: unexpected kubectl $*" >&2; return 1; }
    case "$CJ" in
      on:*) python3 -c 'import sys,json,datetime;n=int(sys.argv[1]);h=int(sys.argv[2]);print(json.dumps({"metadata":{"creationTimestamp":datetime.datetime.fromtimestamp(n-h*3600,datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},"spec":{"suspend":False}}))' "$NOW" "${CJ#on:}" ;;
      suspended) echo '{"metadata":{"creationTimestamp":"2025-01-01T00:00:00Z"},"spec":{"suspend":true}}' ;;
      off) echo 'Error from server (NotFound): cronjobs.batch "claudecode-state-backup" not found' >&2; return 1 ;;
      err) echo 'Error from server (Forbidden): cronjobs.batch "claudecode-state-backup" is forbidden' >&2; return 1 ;;
      *) echo "stub: unknown CJ=$CJ" >&2; return 1 ;;
    esac
  }
  # ⚠️ Per-case reset, and its absence was a real hole (FO-runbook [5fe39a] on
  # #151). `run` unset the stub FUNCTIONS but not these VARIABLES, so
  # DEST_CC_AGE_H survived from the previous case -- and the shipped script
  # assigns it in exactly one place (configmap.yaml:1230), inside the
  # `[[ -n "$DEST_CC_LATEST" ]]` branch. With no claudecode objects the Job
  # therefore sees it UNSET, while this harness saw the previous case's value.
  # So the `cc-none-stays-ok` case never walked the path the Job walks, and a
  # mutation that alerts on `none` BY TESTING THAT UNSET VARIABLE passed.
  # A harness that carries state between cases is testing a tree nobody runs.
  unset DEST_CC_AGE_H DEST_CC_EPOCH DEST_CC_LATEST DEST_CC_COUNT DEST_CC_NOTE \
        DEST_LEVEL DEST_LATE DEST_AGE_H DEST_EPOCH DEST_LATEST DEST_COUNT DEST_JSON \
        DEST_CC_UNPARSEABLE DEST_CC_ARMED DEST_CC_CJ_MSG DEST_CC_CJ_JSON \
        DEST_CC_CJ_CREATED DEST_CC_CJ_EPOCH DEST_CC_CJ_AGE_H
  # shellcheck disable=SC1091
  source "$blk"
  unset -f aws date epoch_of record kubectl 2>/dev/null || true

  local got="${OUT:-<no row>}" lvl bad=""
  lvl="${got%%]*}"; lvl="${lvl#[}"
  LAST_LEVEL="$lvl"
  [[ "$lvl" == "$want" ]] || bad="level [$lvl] != [$want]"
  # Every needle, and they are deliberately WHOLE phrases including numbers.
  # The first version asserted only "claudecode:", which "claudecode: none"
  # also satisfies -- so a mutation making the claudecode age always read empty
  # (object present, report says `none`) PASSED. That is exactly the "we
  # stopped looking at it" green this guard's header claims to catch: the
  # header was ahead of the assertions, and FO-runbook [5fe39a]'s M6/M7/M8 all
  # returned rc=0 against the first version. A pass message that claims more
  # than it verified is worse than no message.
  local n
  for n in "$@"; do
    [[ "$got" == *"$n"* ]] || bad="${bad}${bad:+; }missing '"'"'${n}'"'"'"
  done
  if [[ -z "$bad" ]]; then
    printf 'PASS  %-22s %-14s sys=%-4s cc=%-4s cj=%-9s -> %s\n' "$label" "$cn" "$sysage" "$ccage" "$CJ" "${got:0:54}"
  else
    printf 'FAIL  %-22s %-14s sys=%-4s cc=%-4s cj=%-9s -> %s\n        %s\n' \
      "$label" "$cn" "$sysage" "$ccage" "$CJ" "$got" "$bad"
    FAILED=$((FAILED + 1))
  fi
}

B="$WORK/block.sh"
CJ="on:500"   # default: archive enabled long ago, not suspended (#152)
XA="-"        # default: no extra-instance archive in the prefix
CC1="claudecode: 1h ago, 1 objects"   # the whole phrase, numbers included
# The case the defect lived in: the system archive is three days dead and the
# claudecode one is an hour old. The row must speak about the system archive.
run "$B" db-dead-cc-alive  demo  72  1  fail "newest system archive is 72h old" "$CC1"
# Positive control for the line above: the SAME system age with nothing to mask
# it. Same verdict, so the fail above is about the system archive's age and not
# about the extra object being there.
run "$B" db-dead-alone     demo  72  -  fail "claudecode: none"
# Neither family stale. The COUNT is asserted too: folding both families into
# "system objects" leaves the verdict unchanged and is therefore invisible.
run "$B" both-fresh        demo   2  1  ok   "1 system objects" "$CC1"
# System family absent entirely. "The prefix is not empty" is true and useless.
run "$B" cc-only           demo   -  1  fail "no system archive; $CC1"
# Nothing from claudecode, archive off (CronJob absent): an im/disabled cluster.
CJ=off
run "$B" sys-only          demo   2  -  ok   "1 system objects" "claudecode: none (archive off"
CJ="on:500"
# The thresholds still belong to the system family.
run "$B" db-late-cc-fresh  demo  30  1  warn "newest system archive is 30h old" "$CC1"
# ⚠️ A cluster whose own NAME contains the discriminator. Under a bare
# contains("-claudecode-") the SYSTEM key `jg-claudecode/jg-claudecode-<stamp>`
# matched the claudecode family, leaving zero system objects and a false
# `no system archive` (measured by FO-runbook [5fe39a]). Fail-closed, and still
# a trap for whoever names the next cluster.
run "$B" name-collides     jg-claudecode  2  1  ok "1 system objects" "$CC1"

# --- the claudecode family gets a VERDICT, not just a sentence -------------
# Until 2026-10-03 its age was printed and never compared, so a claudecode
# archive that had stopped uploading left this row at [ok] with the number
# sitting in the prose. These four cases are the difference between reporting a
# family and alerting on it.
run "$B" cc-dead-sys-fresh demo   2 72  fail "claudecode 72h" "claudecode: 72h ago"
run "$B" cc-late-sys-fresh demo   2 30  warn "claudecode 30h"
run "$B" both-stale        demo  72 72  fail "system 72h, claudecode 72h"
# ⚠️ The MIXED case, and it was missing until a mutation found the hole: a
# system family past 48h with a claudecode family only past 26h must stay
# [fail]. `both-stale` does not cover it — there the claudecode age trips the
# fail branch directly and never passes through the warn branch, so replacing
# `[[ $DEST_LEVEL == fail ]] || DEST_LEVEL=warn` with a bare `DEST_LEVEL=warn`
# downgraded a real failure to a warning and every case here still passed.
# A case list only covers the combinations somebody thought to write down.
run "$B" sys-fail-cc-late  demo  72 30  fail "system 72h, claudecode 30h"
# ⚠️ And the case that must NOT fire: no claudecode objects at all is the
# permanent, correct state of every `im/disabled` cluster. A row that cries wolf
# there gets switched off, which costs more than this check is worth.
CJ=off
run "$B" cc-none-stays-ok  demo   2  -  ok   "claudecode: none (archive off"

# --- #152: is the claudecode archive SUPPOSED to be uploading? -------------
# CronJob {present, absent, suspended, unreadable} x claudecode {none, fresh,
# stale}. Each verdict below is asserted as a level AND a phrase, so "ignore
# the discriminator" and "invert it" are caught by a case, not by a crash.
CJ=off
run "$B" off-stale-not-judged  demo  2 72  ok   "claudecode: 72h ago, 1 objects (archive off"
run "$B" off-fresh             demo  2  1  ok   "claudecode: 1h ago, 1 objects (archive off"
run "$B" off-bad-ts-not-judged demo  2 bad ok   "timestamp unparseable (archive off"
run "$B" off-sys-dead-still    demo 72 72  fail "system 72h" "(archive off"
CJ="on:500"
run "$B" on-stale              demo  2 72  fail "claudecode 72h"
run "$B" on-none-long          demo  2  -  fail "claudecode none, enabled 500h ago"
CJ="on:2"
run "$B" on-none-grace         demo  2  -  ok   "first archive pending"
CJ="on:26"
run "$B" on-none-26h           demo  2  -  ok   "enabled 26h ago, first archive pending"
CJ="on:27"
run "$B" on-none-27h           demo  2  -  warn "claudecode none, enabled 27h ago"
CJ="on:48"
run "$B" on-none-48h           demo  2  -  warn "claudecode none, enabled 48h ago"
CJ="on:49"
run "$B" on-none-49h           demo  2  -  fail "claudecode none, enabled 49h ago"
CJ=suspended
run "$B" suspended-fresh       demo  2  1  warn "claudecode archive suspended" "(archive CronJob suspended)"
run "$B" suspended-sys-dead    demo 72  1  fail "system 72h, claudecode archive suspended"
CJ=err
run "$B" unknown-stale-judged  demo  2 72  fail "claudecode 72h" "unreadable: Error from server (Forbidden)"
run "$B" unknown-none-warns    demo  2  -  warn "claudecode none and its CronJob unreadable"
run "$B" unknown-fresh         demo  2  1  ok   "claudecode: 1h ago, 1 objects (archive CronJob unreadable"
CJ="on:500"

# --- #152 item 2: an unreadable claudecode timestamp is warn, not ok --------
run "$B" cc-bad-ts-warns       demo  2 bad warn "claudecode timestamp unparseable"
run "$B" cc-bad-ts-sys-fail    demo 72 bad fail "system 72h, claudecode timestamp unparseable"

# --- #152 item 3: both edges of both thresholds, both families --------------
# The comparisons are `>`: 26h ok, 27h warn; 48h warn, 49h fail. Cases on each
# side so moving an edge by one hour (or by two, which the 2h/30h/72h cases
# above never noticed) is caught.
run "$B" sys-26h               demo 26  1  ok   "fresh (26h ago"
run "$B" sys-27h               demo 27  1  warn "system 27h"
run "$B" sys-48h               demo 48  1  warn "system 48h"
run "$B" sys-49h               demo 49  1  fail "system 49h"
run "$B" cc-26h                demo  2 26  ok   "claudecode: 26h ago"
run "$B" cc-27h                demo  2 27  warn "claudecode 27h"
run "$B" cc-48h                demo  2 48  warn "claudecode 48h"
run "$B" cc-49h                demo  2 49  fail "claudecode 49h"

# --- jg-cluster-template#202: an EXTRA instance's archive in the same prefix --
# It belongs to NEITHER family here, and both directions are a mask:
#   counted as `im`     -> a fresh extra keeps a dead `im` archive looking fine
#   counted as system   -> a fresh extra keeps a dead offsite-backup looking fine
# Ages chosen so each wrong classification changes the verdict, and the
# counts are asserted because the right verdict can survive a wrong count.
XA=1
run "$B" extra-fresh-im-dead   demo  2 72  fail "claudecode 72h" "claudecode: 72h ago, 1 objects"
run "$B" extra-not-in-counts   demo  2  1  ok   "1 system objects" "claudecode: 1h ago, 1 objects"
CJ=off
run "$B" extra-not-system      demo  -  -  fail "no system archive"
CJ="on:500"
XA="-"

echo
# --- control: can this guard see the defect it was written for? -------------
# Rebuild the pre-fix selector FROM THE LIVE BLOCK rather than asserting the
# current text looks right. A guard that only reads the fixed code cannot tell
# a fix from a coincidence.
#
# ⚠️ A control that cannot run must NOT outrank a case that actually failed.
# First version called `exit 2` here directly, and a mutation that flipped the
# selector's polarity produced both a real FAIL and an unrunnable control --
# the exit 2 won and the regression was reported as "cannot measure". Three
# reds (missing tool, broken control, failed assertion) are not one colour,
# and the assertion is the one worth keeping.
CTL_NOTE=""
unmeasurable() { CTL_NOTE="${CTL_NOTE}${CTL_NOTE:+
}cannot measure: $1"; }

sed 's/select(${CC_SEL} | not) | \.LastModified/.LastModified/' "$B" > "$WORK/blind.sh"
if cmp -s "$B" "$WORK/blind.sh"; then
  unmeasurable "the family-blind control changed nothing — the selector is not written the way this control expects, so the passes above are unverified"
else
  # The control is EXPECTED to come back wrong, so its verdict must not be
  # counted as a failure of the shipped code. First version did count it, and
  # the guard reported "1 case wrong" on a correct tree — a guard that flags
  # correct input is the kind that gets switched off.
  _keep=$FAILED
  run "$WORK/blind.sh" CONTROL-blind demo 72  1  fail "newest system archive is 72h old" >/dev/null 2>&1
  FAILED=$_keep
  if [[ "$LAST_LEVEL" == "fail" ]]; then
    unmeasurable "with the family selector removed, the dead-system case STILL reads fail — this guard is not reading the selector, and its passes mean nothing"
  else
    echo "control: removing the family selector flips db-dead-cc-alive from [fail] to [${LAST_LEVEL}] — the defect is reconstructible from the shipped block"
  fi
fi

# Second control, for the claudecode THRESHOLD rather than the selector:
# reconstruct the pre-2026-10-03 behaviour from the live block by deleting that
# threshold, and `cc-dead-sys-fresh` must fall back to [ok]. Without it, an edit
# that drops the threshold while keeping the message passes every case above —
# which is exactly what shipped on 2026-10-01.
# ⚠️ Neutralise the condition rather than delete a line RANGE. The first
# version used `sed '/DEST_CC_AGE_H:-/,/^ *fi$/d'`, which took the inner `fi`
# and left the outer one: the mutated block failed `bash -n` (11 `fi` -> 10),
# bash refused to source it, every case came back unchanged, and the control
# printed "reconstructible" anyway. A control that cannot run its own mutation
# reads exactly like a control that ran and agreed (FO-runbook [5fe39a], #151).
sed 's/if \[\[ -n "${DEST_CC_AGE_H:-}" \]\] && (( DEST_CC_COUNT > 0 )); then/if false; then/' "$B" > "$WORK/nothresh.sh"
if cmp -s "$B" "$WORK/nothresh.sh"; then
  # Most often this means the condition was EDITED -- including by whatever
  # mutation is being tested right now, since a control that mutates the thing
  # under test collides with mutations of that same thing. That collision is
  # acceptable (a real FAIL still outranks this note) but it must not read as a
  # pass, so it is reported with its likely cause rather than as a bare miss.
  unmeasurable "the claudecode-threshold control matched nothing — the condition it mutates was rewritten (possibly by the change under test), so the four verdict cases are unverified on this tree"
elif ! bash -n "$WORK/nothresh.sh" 2>/dev/null; then
  unmeasurable "the claudecode-threshold control produced a block that does not parse, so it was never executed — and an unexecuted mutation returns the same readings as one that was caught"
else
  _k=$FAILED
  run "$WORK/nothresh.sh" CONTROL-nothresh demo 2 72 fail "claudecode 72h" >/dev/null 2>&1
  FAILED=$_k
  if [[ "$LAST_LEVEL" == "fail" ]]; then
    unmeasurable "with the claudecode threshold deleted, a 72h-old claudecode archive STILL read fail — the verdict cases are not reading that threshold"
  else
    echo "control: deleting the claudecode threshold drops cc-dead-sys-fresh from [fail] to [${LAST_LEVEL}] — the pre-2026-10-03 behaviour is reconstructible"
  fi
fi

# Third control, for the extra-instance split: point the `im` verdict back at
# the any-claudecode selector, and the extra's fresh archive must mask the dead
# `im` one. Rebuilt from the live block, so a block that no longer has two
# selectors makes this say so instead of passing.
sed 's/select(${CC_IM_SEL})/select(${CC_SEL})/g' "$B" > "$WORK/imblind.sh"
if cmp -s "$B" "$WORK/imblind.sh"; then
  unmeasurable "the im-selector control changed nothing — the block no longer selects the im family with CC_IM_SEL, so the extra-instance cases are unverified"
else
  _k=$FAILED
  XA=1; run "$WORK/imblind.sh" CONTROL-imblind demo 2 72 fail "claudecode 72h" >/dev/null 2>&1; XA="-"
  FAILED=$_k
  if [[ "$LAST_LEVEL" == "fail" ]]; then
    unmeasurable "with the im selector widened to every claudecode key, a fresh extra archive did NOT mask the dead im one — the extra-instance cases are not reading CC_IM_SEL"
  else
    echo "control: widening the im selector to every claudecode key drops extra-fresh-im-dead from [fail] to [${LAST_LEVEL}] — the mask is reconstructible"
  fi
fi

if [[ $FAILED -ne 0 ]]; then
  [[ -n "$CTL_NOTE" ]] && echo "note: a control could not run either — ${CTL_NOTE#cannot measure: }"
  echo "FAIL — ${FAILED} case(s) wrong"
  exit 1
fi
if [[ -n "$CTL_NOTE" ]]; then
  echo "$CTL_NOTE"
  exit 2
fi
echo "PASS — row 21 gives BOTH families a verdict (worst wins) and names both in every outcome; the system object count excludes claudecode; the claudecode family is judged only when its CronJob exists (absent: reported, not judged; suspended: warn; unreadable: warn when empty), an empty family on an enabled cluster is judged by the CronJob's age; an unparseable claudecode timestamp is warn; both edges of 26h/48h hold for both families; a cluster named *-claudecode-* is still classified correctly; and an extra instance's archive (jg-cluster-template#202) is counted in neither family, so it masks neither"
exit 0
