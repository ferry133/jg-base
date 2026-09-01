#!/usr/bin/env bash
# Assert what daily-check's off-site backup COVERAGE row emits, per published status.
#
# ferry133/jg-base#54: on an appliance the mandatory backup ran every night,
# succeeded, and staged nothing — because the only thing it captured was
# databases and an appliance has none. The backup's own log printed
# `encrypted: 1626 bytes` daily and **nothing anywhere said that number was too
# small**.
#
# The fix publishes `staged_bytes` and this row reports it. The case that must
# not regress is the last one below: **0 staged bytes is a warn, not an ok.**
# Every other case in this file exists so that assertion cannot be met by a row
# that simply warns about everything.
#
# It sources the real block out of the ConfigMap rather than restating its
# logic. A copy here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-backup-coverage-row.sh   (exit 0 if every case matches)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for tool in yq jq; do
  command -v "$tool" >/dev/null || {
    echo "$tool required. CI installs yq pinned in the 'scripts' job of"
    echo ".github/workflows/flux-local.yaml; jq ships on the runner image."
    exit 1
  }
done
yq -r '.data."run-check.sh"' "$CM" > "$WORK/run-check.sh"

python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1])
s = (work / "run-check.sh").read_text()
try:
    start = s.index("# 20. Off-site backup coverage")
    end = s.index("# 21. Off-site backup destination")
except ValueError:
    sys.exit("could not locate the coverage block in run-check.sh — markers moved")
blk = s[start:end]
if "offsite-backup-status" not in blk:
    sys.exit("located a block, but it never reads the status ConfigMap — wrong slice")
if "staged_bytes" not in blk:
    sys.exit("located a block that never reads staged_bytes — the #54 fix is gone")
(work / "block.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

NOW=1767225600
FAILED=0
declare -A SEEN=()

# $1=label  $2=status JSON data object (or "ERR:<msg>" / "NOTFOUND")  $3=expected prefix
run() {
  local label="$1" data="$2" want="$3"
  OUT=""
  BACKUP_R2_BUCKET="demo-backup"
  record() { OUT="[$1] $2${3:+ — $3}"; }
  date() { if [[ "$*" == "-u +%s" ]]; then echo "$NOW"; else command date "$@"; fi; }
  epoch_of() { echo $(( NOW - 3600 )); }   # 1h old unless a case overrides
  case "$data" in
    NOTFOUND) kubectl() { echo 'Error from server (NotFound): configmaps "offsite-backup-status" not found' >&2; return 1; } ;;
    ERR:*)    kubectl() { echo "${data#ERR:}" >&2; return 1; } ;;
    OLD:*)    kubectl() { printf '{"data":%s}\n' "${data#OLD:}"; }
              epoch_of() { echo $(( NOW - 40 * 3600 )); } ;;
    *)        kubectl() { printf '{"data":%s}\n' "$data"; } ;;
  esac

  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  unset -f kubectl date epoch_of record 2>/dev/null || true

  local got="${OUT:-<no row>}"
  local level="${got%%]*}"; level="${level#[}"
  SEEN["$label"]="$level"
  if [[ "$got" == "$want"* ]]; then
    printf 'PASS  %-20s -> %s\n' "$label" "${got:0:86}"
  else
    printf 'FAIL  %-20s -> %s\n        expected %s...\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

OKDATA='{"timestamp":"2026-09-01T00:00:00Z","dumped":"db/postgres claudecode/im-config","absent":"","failed":"","regressed":"","staged_bytes":"1572864"}'

run healthy   "$OKDATA" "[ok] Off-site backup coverage (db/postgres claudecode/im-config, 1572864 bytes staged)"

# A database that failed, and one that stopped being dumped. Both name it.
run failed    '{"timestamp":"2026-09-01T00:00:00Z","dumped":"","absent":"","failed":"freepbx/mariadb","regressed":"","staged_bytes":"0"}'   "[fail]"
run regressed '{"timestamp":"2026-09-01T00:00:00Z","dumped":"db/postgres","absent":"claudecode/im-config","failed":"","regressed":"claudecode/im-config","staged_bytes":"120"}' "[fail]"

# The status is unreadable, or not published yet. Neither is a healthy backup
# and neither is a broken one.
run not-published NOTFOUND                                  "[warn]"
run unreadable    "ERR:the server could not find the requested resource" "[warn]"

# Published, but describing a run from a day and a half ago.
run stale-status  "OLD:$OKDATA"                             "[warn]"

# ── #54's condition, and the reason this file exists ────────────────────────
# Nothing failed, nothing regressed, no database is installed — and the backup
# staged zero bytes. Every source-side signal is green and the archive is empty.
# This MUST NOT be ok.
run zero-bytes '{"timestamp":"2026-09-01T00:00:00Z","dumped":"","absent":"db/postgres claudecode/claude-config","failed":"","regressed":"","staged_bytes":"0"}' \
  "[warn] Off-site backup coverage — ran and staged 0 bytes"

echo

if [[ "${SEEN[zero-bytes]}" == "ok" ]]; then
  echo "FAIL  a backup that staged 0 bytes reported ok — that is #54 exactly,"
  echo "      and every source-side signal in that case was green."
  FAILED=$((FAILED + 1))
fi
if [[ "${SEEN[healthy]}" != "ok" ]]; then
  echo "FAIL  a healthy backup did not report ok — a row that warns at every"
  echo "      input satisfies the assertion above and carries no information."
  FAILED=$((FAILED + 1))
fi

DISTINCT=$(printf '%s\n' "${SEEN[@]}" | sort -u | wc -l | tr -d ' ')
if (( DISTINCT < 3 )); then
  echo "FAIL  only ${DISTINCT} distinct level(s) across ${#SEEN[@]} cases — the"
  echo "      stubs are probably not reaching the block."
  FAILED=$((FAILED + 1))
fi

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — ${#SEEN[@]} cases match, ${DISTINCT} distinct levels, 0 bytes ≠ ok"
