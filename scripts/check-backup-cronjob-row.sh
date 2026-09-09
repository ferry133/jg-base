#!/usr/bin/env bash
# Assert what daily-check's backup-CronJob row emits, per cluster state.
#
# ferry133/jg-base#83: the row read `kubectl -n db get cronjob postgres-backup`.
# The namespace was pinned. #73 moved the claudecode postgres into base, whose
# backup CronJob is in namespace `claudecode`, and freepbx's `mariadb-backup`
# has been in `freepbx` all along — so two of the three backup CronJobs this
# repo ships were invisible to the row that is named after them. On jg-jiahd
# that backup had never completed once, for two months, and the daily report
# said nothing: row 6 `skip`, row 19 green.
#
# The two cases that must not regress are at the bottom of this file:
#   * a CronJob that has NEVER succeeded must fail (that is jg-jiahd exactly);
#   * a CronJob outside namespace `db` must be SEEN at all (that is #83).
# Every other case exists so those two cannot be satisfied by a row that
# simply fails at everything, or by one that reports a row for anything.
#
# It sources the real block out of the ConfigMap rather than restating its
# logic. A copy here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-backup-cronjob-row.sh   (exit 0 if every case matches)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null || { echo "jq required (ships on the CI runner image)"; exit 1; }

# Extract data."run-check.sh" without yq: this row's guard should not need a
# toolchain the runner might not have installed yet when it is wired in.
python3 - "$CM" "$WORK/run-check.sh" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text().splitlines(True)
out, on, indent = [], False, None
for ln in src:
    if not on:
        if ln.strip().startswith("run-check.sh:") and ln.rstrip().endswith("|"):
            on = True
        continue
    if ln.strip() == "":
        out.append("\n"); continue
    cur = len(ln) - len(ln.lstrip())
    if indent is None:
        indent = cur
    if cur < indent:
        break
    out.append(ln[indent:])
if not out:
    sys.exit("could not extract run-check.sh from the ConfigMap")
Path(sys.argv[2]).write_text("".join(out))
PY

python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1])
s = (work / "run-check.sh").read_text()
try:
    start = s.index("# 6. Backup CronJobs")
    end = s.index("# 7. Postgres pod")
except ValueError:
    sys.exit("could not locate the backup-CronJob block in run-check.sh — markers moved")
blk = s[start:end]
if "get cronjob -A" not in blk:
    sys.exit("located a block that does not enumerate cronjobs cluster-wide — #83 is gone")
if "lastSuccessfulTime" not in blk:
    sys.exit("located a block that never reads lastSuccessfulTime — wrong slice")
(work / "block.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

NOW=1767225600
FAILED=0
declare -A SEEN=()

# Build one CronJob item. $1=ns $2=name $3=suspend $4=lastSuccessfulTime
# ("" = never succeeded, "BAD" = present but unparseable, "AGE:<h>" = h hours old)
cj() {
  local last_json='null'
  [[ -n "$4" ]] && last_json="\"$4\""
  printf '{"metadata":{"namespace":"%s","name":"%s"},"spec":{"suspend":%s},"status":{"lastSuccessfulTime":%s}}' \
    "$1" "$2" "$3" "$last_json"
}

# $1=label  $2=items JSON array body (or "ERR")  $3=expected rows, one per line
run() {
  local label="$1" items="$2" want="$3"
  ROWS=()
  record() { ROWS+=("[$1] $2${3:+ — $3}"); }
  date() { if [[ "$*" == "-u +%s" ]]; then echo "$NOW"; else command date "$@"; fi; }
  # Explicit, not real parsing: this file tests the row's branches. epoch_of
  # itself is exercised by the sibling row guards and by check 19.
  epoch_of() {
    case "$1" in
      AGE:*) echo $(( NOW - ${1#AGE:} * 3600 )) ;;
      *)     : ;;                                  # unparseable -> empty
    esac
  }
  if [[ "$items" == "ERR" ]]; then
    kubectl() { echo 'Error from server (Forbidden): cronjobs is forbidden' >&2; return 1; }
  else
    kubectl() { printf '{"items":[%s]}\n' "$items"; }
  fi

  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  unset -f kubectl date epoch_of record 2>/dev/null || true

  local got; got="$(printf '%s\n' "${ROWS[@]:-<no row>}")"
  SEEN["$label"]="$got"
  if [[ "$got" == "$want" ]]; then
    printf 'PASS  %-22s -> %s\n' "$label" "$(echo "$got" | head -1 | cut -c1-78)"
  else
    printf 'FAIL  %-22s\n  got:\n%s\n  want:\n%s\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

# ── the ordinary night ──────────────────────────────────────────────────────
run healthy "$(cj db postgres-backup false AGE:6)" \
"[ok] Backup db/postgres-backup (last success 6h ago)
[ok] Backup CronJobs measured: 1"

# ── freshness, three outcomes not two ───────────────────────────────────────
run late "$(cj db postgres-backup false AGE:30)" \
"[warn] Backup db/postgres-backup late — last success 30h ago
[ok] Backup CronJobs measured: 1"

run stale "$(cj db postgres-backup false AGE:70)" \
"[fail] Backup db/postgres-backup stale — last success 70h ago (AGE:70)
[ok] Backup CronJobs measured: 1"

run unparseable "$(cj db postgres-backup false 2026-13-45T99:00:00Z)" \
"[warn] Backup db/postgres-backup — cannot parse last success time (2026-13-45T99:00:00Z)
[ok] Backup CronJobs measured: 1"

# Suspended is a measured state, so it is not skip; and from the data's point
# of view it is not ok either.
run suspended "$(cj claudecode postgres-backup true AGE:6)" \
"[warn] Backup claudecode/postgres-backup — CronJob is suspended — no new backups are being taken
[ok] Backup CronJobs measured: 1"

# ── absence vs. inability to look: they must not render the same ────────────
run none "" \
"[skip] Backup CronJobs — no backup CronJob is deployed on this cluster, so this row measured nothing — it is not a statement that the data is unprotected, nor that it is protected (off-site backup is a separate row)"

run rbac-lost "ERR" \
"[warn] Backup CronJobs — could not list CronJobs cluster-wide (RBAC or API error) — this row measured nothing"

# offsite-backup has its own row (check 19) with logic this one has not got.
# It must not appear here, and its presence must not make the cluster look
# like it has a backup CronJob when it has none.
run offsite-only "$(cj monitoring offsite-backup false AGE:6)" \
"[skip] Backup CronJobs — no backup CronJob is deployed on this cluster, so this row measured nothing — it is not a statement that the data is unprotected, nor that it is protected (off-site backup is a separate row)"

# ── #83: the fleet as it actually is ────────────────────────────────────────
# Three backup CronJobs in three namespaces, exactly what this repo ships, plus
# the off-site job that must be filtered out. The pinned-namespace spelling saw
# one of these four.
run three-namespaces \
"$(cj claudecode postgres-backup false ''),$(cj db postgres-backup false AGE:6),$(cj freepbx mariadb-backup false AGE:6),$(cj monitoring offsite-backup false AGE:6)" \
"[fail] Backup claudecode/postgres-backup — has never completed successfully (status.lastSuccessfulTime is unset)
[ok] Backup db/postgres-backup (last success 6h ago)
[ok] Backup freepbx/mariadb-backup (last success 6h ago)
[ok] Backup CronJobs measured: 3"

# ── the case this file exists for ───────────────────────────────────────────
# jg-jiahd exactly: the CronJob is there, the schedule fires, the PVC never
# binds, and nothing has ever completed. This MUST be fail. It rendered as
# nothing at all for two months.
run never-succeeded "$(cj claudecode postgres-backup false '')" \
"[fail] Backup claudecode/postgres-backup — has never completed successfully (status.lastSuccessfulTime is unset)
[ok] Backup CronJobs measured: 1"

# ── the thresholds, with the REAL epoch_of and REAL timestamps ──────────────
# FO-handler [f92b04] verified this row against three live clusters and said
# plainly what it had NOT covered: `epoch_of` never executed, because it stubbed
# BSD `date` in its place. So the >26h and >48h branches had been asserted only
# against a stub returning whatever each case asked for — which proves the
# branch order and nothing about parsing.
#
# These cases run the real `epoch_of` out of run-check.sh against real RFC3339
# strings. That is the same first branch production takes: cronjob.yaml's
# `apk add bash bind-tools` is only the bootstrap that gets bash, and
# run-check.sh's own install line then adds coreutils, so `date -u -d` there is
# GNU. Checked rather than taken from the comment above epoch_of — a stale
# comment would have sent this file testing the wrong branch.
EPOCH_OF_SRC="$(sed -n '/^epoch_of() {/,/^}/p' "$WORK/run-check.sh")"
[[ -n "$EPOCH_OF_SRC" ]] || { echo "could not extract epoch_of from run-check.sh"; exit 1; }
eval "$EPOCH_OF_SRC"

rfc3339_ago() {  # $1 = hours before NOW
  python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp($NOW-int(sys.argv[1])*3600,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}
TS_FRESH="$(rfc3339_ago 6)"
TS_LATE="$(rfc3339_ago 30)"
TS_STALE="$(rfc3339_ago 70)"

# Same as run(), but epoch_of is the real one rather than a stub.
run_real() {
  local label="$1" items="$2" want="$3"
  ROWS=()
  record() { ROWS+=("[$1] $2${3:+ — $3}"); }
  date() { if [[ "$*" == "-u +%s" ]]; then echo "$NOW"; else command date "$@"; fi; }
  kubectl() { printf '{"items":[%s]}\n' "$items"; }
  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  unset -f kubectl date record 2>/dev/null || true
  local got; got="$(printf '%s\n' "${ROWS[@]:-<no row>}")"
  SEEN["$label"]="$got"
  if [[ "$got" == "$want" ]]; then
    printf 'PASS  %-22s -> %s\n' "$label" "$(echo "$got" | head -1 | cut -c1-78)"
  else
    printf 'FAIL  %-22s\n  got:\n%s\n  want:\n%s\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

# GNU `date -u -d` is what production takes. BSD date (a macOS checkout) has
# neither that nor busybox's -D, so epoch_of returns empty there and these cases
# would quietly assert the "cannot parse" branch instead — passing while
# measuring nothing. Not run, said out loud, and an error in CI so the silence
# cannot become permanent.
if command date -u -d @0 +%s >/dev/null 2>&1; then
  run_real real-fresh "$(cj db postgres-backup false "$TS_FRESH")" \
"[ok] Backup db/postgres-backup (last success 6h ago)
[ok] Backup CronJobs measured: 1"

  run_real real-late "$(cj db postgres-backup false "$TS_LATE")" \
"[warn] Backup db/postgres-backup late — last success 30h ago
[ok] Backup CronJobs measured: 1"

  run_real real-stale "$(cj db postgres-backup false "$TS_STALE")" \
"[fail] Backup db/postgres-backup stale — last success 70h ago ($TS_STALE)
[ok] Backup CronJobs measured: 1"
elif [[ -n "${CI:-}" ]]; then
  echo "FAIL  GNU date is absent on a CI runner, so the threshold cases did not"
  echo "      run. They are the only ones exercising the real epoch_of, and a"
  echo "      silent skip here is how this row stops being tested."
  FAILED=$((FAILED + 1))
else
  echo "NOT RUN  real-fresh/real-late/real-stale — no GNU date on this machine;"
  echo "         they exercise the real epoch_of and they run in CI."
fi

echo

# ── cross-case assertions ───────────────────────────────────────────────────
# Per-case expectations above can all be edited to match a broken row at once.
# These say the same things again in a form that an edit has to contradict.

if [[ "${SEEN[never-succeeded]}" != *"[fail]"* ]]; then
  echo "FAIL  a CronJob that has never succeeded did not fail — that is jg-jiahd"
  echo "      exactly (#82), and it is what this row was blind to for two months."
  FAILED=$((FAILED + 1))
fi

if [[ "${SEEN[three-namespaces]}" != *"claudecode/postgres-backup"* ]] \
|| [[ "${SEEN[three-namespaces]}" != *"freepbx/mariadb-backup"* ]]; then
  echo "FAIL  a backup CronJob outside namespace 'db' was not reported. That is"
  echo "      #83: the row did not break, it stopped pointing at them."
  FAILED=$((FAILED + 1))
fi

if [[ "${SEEN[three-namespaces]}" == *"offsite-backup"* ]]; then
  echo "FAIL  offsite-backup appeared in this row. Check 19 measures it with"
  echo "      logic this row has not got; two rows for one job make the report"
  echo "      look wider than it is."
  FAILED=$((FAILED + 1))
fi

if [[ "${SEEN[none]}" == "${SEEN[rbac-lost]}" ]]; then
  echo "FAIL  'no backup CronJob here' and 'could not look' rendered identically."
  echo "      Three outcomes, not two — the second one is not an absence."
  FAILED=$((FAILED + 1))
fi

if [[ "${SEEN[healthy]}" != *"[ok]"* ]]; then
  echo "FAIL  an ordinary healthy night did not report ok, so every assertion"
  echo "      above could be met by a row that simply fails at everything."
  FAILED=$((FAILED + 1))
fi

if (( FAILED > 0 )); then
  echo "FAILED: $FAILED case(s)"
  exit 1
fi
echo "ok — every case matches, including the two that must not regress"
