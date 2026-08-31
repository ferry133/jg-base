#!/usr/bin/env bash
# Assert what daily-check's off-site backup DESTINATION row emits, per input.
#
# ferry133/jg-base#49 asked for this row because checks 19 and 20 are both
# source-side and cannot see the destination. Its acceptance condition is one
# sentence: **`fail` and `skip` must be distinguishable.** That is the whole
# point — "the archive is not there" and "we could not look" are different
# facts, and a row that reports a network blip as data loss gets switched off,
# taking the real signal with it.
#
# So this file does two things. It pins the classification of every input, and
# it then asserts explicitly that the empty-prefix case and the unreachable-
# endpoint case did NOT land on the same level. The second assertion is the one
# that would catch a future edit collapsing them back together, because that
# edit would keep every individual case looking reasonable.
#
# It sources the real block out of the ConfigMap rather than restating its
# logic. A copy here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-offsite-destination-row.sh   (exit 0 if every case matches)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v yq >/dev/null || {
  # Loud, not silent — the same trade check-lan-dns-row.sh refuses to make.
  echo "yq required. CI installs it pinned (version + sha256) in the"
  echo "'scripts' job of .github/workflows/flux-local.yaml; match that"
  echo "version locally rather than picking one."
  exit 1
}
yq -r '.data."run-check.sh"' "$CM" > "$WORK/run-check.sh"

# Slice out the block under test. Failing to find it must abort, never silently
# test an empty file — that is the shape this whole script exists to prevent.
python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1])
s = (work / "run-check.sh").read_text()
try:
    start = s.index("# 21. Off-site backup destination")
    end = s.index("# 22. Stalled provisioning tickets")
except ValueError:
    sys.exit("could not locate the destination block in run-check.sh — markers moved")
blk = s[start:end]
if "list-objects-v2" not in blk:
    sys.exit("located a block, but it never lists the destination — wrong slice")
if "record skip" not in blk or "record fail" not in blk:
    sys.exit("located a block that cannot emit both skip and fail — wrong slice")
(work / "block.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

NOW=1767225600          # fixed "now" so ages are arithmetic, not wall-clock
FAILED=0
declare -A SEEN_LEVEL=()

# $1=case label  $2=aws mode  $3=object age in hours (or "-")  $4=expected prefix
run() {
  local label="$1" mode="$2" age="$3" want="$4"
  OUT=""
  CLUSTER_NAME="demo"
  BACKUP_R2_BUCKET="demo-backup"
  BACKUP_R2_ENDPOINT="https://minio.example.cc"
  BACKUP_R2_ACCESS_KEY_ID="AKIA"
  BACKUP_R2_SECRET_ACCESS_KEY="s3cr3t"

  record() { OUT="[$1] $2${3:+ — $3}"; }
  # `date -u +%s` must be deterministic; every other date call falls through.
  date() { if [[ "$*" == "-u +%s" ]]; then echo "$NOW"; else command date "$@"; fi; }
  epoch_of() { [[ "$1" == UNPARSEABLE ]] && return 0; echo $(( NOW - age * 3600 )); }

  # Defining `aws` as a function is also what makes `command -v aws` succeed —
  # so the no-aws case below simply does not define it.
  case "$mode" in
    ok)        aws() { printf '{"Contents":[{"Key":"demo/a.age","LastModified":"2026-08-30T08:00:00+00:00"}]}\n'; } ;;
    empty)     aws() { printf '{"RequestCharged":null}\n'; } ;;
    unparse)   aws() { printf '{"Contents":[{"Key":"demo/a.age","LastModified":"UNPARSEABLE"}]}\n'; }
               epoch_of() { return 0; } ;;
    offline)   aws() { echo "Could not connect to the endpoint URL: \"https://minio.example.cc\"" >&2; return 255; } ;;
    denied)    aws() { echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; return 1; } ;;
    nocreds)   aws() { printf '{}\n'; }; BACKUP_R2_SECRET_ACCESS_KEY="" ;;
    noendpoint) aws() { printf '{}\n'; }; BACKUP_R2_ENDPOINT="" ;;
    noaws)     : ;;   # deliberately no function -> command -v aws fails
    unset)     aws() { printf '{}\n'; }; BACKUP_R2_BUCKET="" ;;
  esac

  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  unset -f aws date epoch_of record 2>/dev/null || true

  local got="${OUT:-<no row>}"
  local level="${got%%]*}"; level="${level#[}"
  SEEN_LEVEL["$label"]="$level"
  if [[ "$got" == "$want"* ]]; then
    printf 'PASS  %-22s aws=%-11s age=%-4s -> %s\n' "$label" "$mode" "$age" "${got:0:78}"
  else
    printf 'FAIL  %-22s aws=%-11s age=%-4s -> %s\n        expected %s...\n' \
      "$label" "$mode" "$age" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

# The destination is readable and holds something.
run fresh            ok         2   "[ok]"
run late             ok         30  "[warn]"
run stale            ok         60  "[fail]"

# Readable, and genuinely empty. A delete marker on a versioned, object-locked
# bucket looks exactly like this — the case the issue was opened for.
run empty-prefix     empty      -   "[fail]"

# Not readable. Every one of these is "we could not look", NOT "it is gone".
run endpoint-offline offline    -   "[skip]"
run access-denied    denied     -   "[skip]"
run creds-unset      nocreds    -   "[skip]"
run endpoint-unset   noendpoint -   "[skip]"
run aws-missing      noaws      -   "[skip]"

# Readable, but the timestamp means nothing. Said as unknown rather than guessed
# in either direction: low invents a healthy backup, high invents an outage.
run bad-timestamp    unparse    -   "[warn]"

# No bucket at all: this row does not apply and must stay silent. Checks 19/20
# already carry the "not configured" statement; a second one would double-count.
run bucket-unset     unset      -   "<no row>"

echo

# The acceptance condition, asserted rather than left to the reader.
if [[ "${SEEN_LEVEL[empty-prefix]}" == "${SEEN_LEVEL[endpoint-offline]}" ]]; then
  echo "FAIL  an empty destination and an unreachable endpoint both reported"
  echo "      '${SEEN_LEVEL[empty-prefix]}' — that is exactly the conflation #49"
  echo "      exists to remove, moved one field over."
  FAILED=$((FAILED + 1))
fi

# A harness that wires nothing produces one level for every case, and every
# individual assertion above would still look reasonable.
DISTINCT=$(printf '%s\n' "${SEEN_LEVEL[@]}" | sort -u | wc -l | tr -d ' ')
if (( DISTINCT < 4 )); then
  echo "FAIL  only ${DISTINCT} distinct level(s) across ${#SEEN_LEVEL[@]} cases —"
  echo "      the stubs are probably not reaching the block."
  FAILED=$((FAILED + 1))
fi

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — ${#SEEN_LEVEL[@]} cases match, ${DISTINCT} distinct levels, fail≠skip"
