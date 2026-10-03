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

mkfix() { # mkfix <cluster> <system age h|-> <claudecode age h|->
  python3 - "$NOW" "$1" "$2" "$3" <<'PY'
import sys, json, datetime
now, cn, sysage, ccage = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
def ts(h):
    t = datetime.datetime.fromtimestamp(now - int(h) * 3600, datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S+00:00")
# Keys built from the cluster name the way the two uploaders build them
# (monitoring/backup backup.sh, claudecode archive.sh), so a cluster name
# containing "-claudecode-" produces the colliding shape for real instead of
# being asserted about.
c = []
if sysage != "-": c.append({"Key": "%s/%s-20260930T190000Z.tar.gz.age" % (cn, cn), "LastModified": ts(sysage)})
if ccage  != "-": c.append({"Key": "%s/%s-claudecode-20261001T190000Z.tar.gz.age" % (cn, cn), "LastModified": ts(ccage)})
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
  # shellcheck disable=SC1091
  source "$blk"
  unset -f aws date epoch_of record 2>/dev/null || true

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
    printf 'PASS  %-18s %-14s sys=%-4s cc=%-4s -> %s\n' "$label" "$cn" "$sysage" "$ccage" "${got:0:54}"
  else
    printf 'FAIL  %-18s %-14s sys=%-4s cc=%-4s -> %s\n        %s\n' \
      "$label" "$cn" "$sysage" "$ccage" "$got" "$bad"
    FAILED=$((FAILED + 1))
  fi
}

B="$WORK/block.sh"
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
# Nothing from claudecode yet -- every cluster, until this ships.
run "$B" sys-only          demo   2  -  ok   "1 system objects" "claudecode: none"
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
run "$B" cc-none-stays-ok  demo   2  -  ok   "claudecode: none"

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
sed '/DEST_CC_AGE_H:-/,/^ *fi$/d' "$B" > "$WORK/nothresh.sh"
if cmp -s "$B" "$WORK/nothresh.sh"; then
  unmeasurable "the claudecode-threshold control changed nothing, so the four verdict cases are unverified"
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

if [[ $FAILED -ne 0 ]]; then
  [[ -n "$CTL_NOTE" ]] && echo "note: a control could not run either — ${CTL_NOTE#cannot measure: }"
  echo "FAIL — ${FAILED} case(s) wrong"
  exit 1
fi
if [[ -n "$CTL_NOTE" ]]; then
  echo "$CTL_NOTE"
  exit 2
fi
echo "PASS — row 21 gives BOTH families a verdict (worst wins) and names both in every outcome; the system object count excludes claudecode; an absent claudecode family stays [ok]; and a cluster named *-claudecode-* is still classified correctly"
exit 0
