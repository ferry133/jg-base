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

mkfix() { # mkfix <system age h|-> <claudecode age h|->
  python3 - "$NOW" "$1" "$2" <<'PY'
import sys, json, datetime
now, sysage, ccage = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def ts(h):
    t = datetime.datetime.fromtimestamp(now - int(h) * 3600, datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S+00:00")
c = []
if sysage != "-": c.append({"Key": "demo/demo-20260930T190000Z.tar.gz.age", "LastModified": ts(sysage)})
if ccage  != "-": c.append({"Key": "demo/demo-claudecode-20261001T190000Z.tar.gz.age", "LastModified": ts(ccage)})
print(json.dumps({"Contents": c} if c else {"RequestCharged": None}))
PY
}

FAILED=0
run() { # run <block> <label> <sysage> <ccage> <want-level> <must-contain>
  local blk="$1" label="$2" sysage="$3" ccage="$4" want="$5" needle="$6"
  local fixture; fixture="$(mkfix "$sysage" "$ccage")"
  OUT=""
  CLUSTER_NAME="demo"; BACKUP_R2_BUCKET="demo-backup"
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

  local got="${OUT:-<no row>}" lvl
  lvl="${got%%]*}"; lvl="${lvl#[}"
  LAST_LEVEL="$lvl"
  if [[ "$lvl" == "$want" ]] && [[ "$got" == *"$needle"* ]]; then
    printf 'PASS  %-20s sys=%-4s cc=%-4s -> %s\n' "$label" "$sysage" "$ccage" "${got:0:76}"
  else
    printf 'FAIL  %-20s sys=%-4s cc=%-4s -> %s\n        wanted level [%s] containing %q\n' \
      "$label" "$sysage" "$ccage" "$got" "$want" "$needle"
    FAILED=$((FAILED + 1))
  fi
}

B="$WORK/block.sh"
# The case the defect lived in: the system archive is three days dead and the
# claudecode one is an hour old. The row must speak about the system archive.
run "$B" db-dead-cc-alive   72  1  fail "claudecode:"
# Positive control for the line above: the SAME system age with nothing to mask
# it. Same verdict, so the fail above is about the system archive's age and not
# about the extra object being there.
run "$B" db-dead-alone      72  -  fail "claudecode: none"
# Neither family stale.
run "$B" both-fresh          2  1  ok   "claudecode:"
# System family absent entirely. "The prefix is not empty" is true and useless.
run "$B" cc-only             -  1  fail "no system archive"
# Nothing from claudecode yet (every cluster, until this ships).
run "$B" sys-only            2  -  ok   "claudecode: none"
# The thresholds still belong to the system family.
run "$B" db-late-cc-fresh   30  1  warn "claudecode:"

echo
# --- control: can this guard see the defect it was written for? -------------
# Rebuild the pre-fix selector FROM THE LIVE BLOCK rather than asserting the
# current text looks right. A guard that only reads the fixed code cannot tell
# a fix from a coincidence.
sed 's/select(${CC_SEL} | not) | \.LastModified/.LastModified/' "$B" > "$WORK/blind.sh"
if cmp -s "$B" "$WORK/blind.sh"; then
  echo "cannot measure: the family-blind control changed nothing — the selector is not written the way this control expects, so every PASS above is unverified"
  exit 2
fi
# The control is EXPECTED to come back wrong, so its verdict must not be
# counted as a failure of the shipped code. First version did count it, and
# the guard reported "1 case wrong" on a correct tree — a guard that flags
# correct input is the kind that gets switched off.
_keep=$FAILED
run "$WORK/blind.sh" CONTROL-blind    72  1  fail "claudecode:" >/dev/null 2>&1
FAILED=$_keep
if [[ "$LAST_LEVEL" == "fail" ]]; then
  echo "cannot measure: with the family selector removed, the dead-system case STILL reads fail — this guard is not reading the selector, and its passes mean nothing"
  exit 2
fi
echo "control: removing the family selector flips db-dead-cc-alive from [fail] to [${LAST_LEVEL}] — the defect is reconstructible from the shipped block"

if [[ $FAILED -ne 0 ]]; then
  echo "FAIL — ${FAILED} case(s) wrong"
  exit 1
fi
echo "PASS — row 21 verdicts follow the system family, and all six outcomes still name the claudecode family"
exit 0
