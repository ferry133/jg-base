#!/usr/bin/env bash
# Assert what daily-check's LAN internal-name row emits, per input.
#
# The row raises a LAN-wide alarm, and two of its outcomes are invisible in any
# artifact: emitting nothing (which reads exactly like a passing check) and
# alarming on a cluster whose LAN is fine. Both were shipped before —
# ferry133/jg-base#18 failed every morning on every appliance because it asked
# whether the ROUTER resolves, a question the shipping default has no answer to.
#
# Since #16 the gate is NODE_DNS_PATH (lan | public | empty) rather than a
# boolean, and the two non-probe states emit an explicit "not measured" row
# instead of nothing. The cases below are what holds that in place.
#
# It sources the real block out of the ConfigMap rather than restating its
# logic. A copy here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-lan-dns-row.sh    (exit 0 if every case matches)
#
# Run by CI since ferry133/jg-base#32 — the `scripts` job in
# .github/workflows/flux-local.yaml, gated by `Flux Local Success`.
# Before that nothing executed it: it had guarded a row that shipped
# broken twice while never once being run, and an unrun test and a
# passing test are the same colour on a pull request.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v yq >/dev/null || {
  # Loud, not silent — a `|| exit 0` here would turn "I could not measure"
  # into "passed", which is the exact trade this script exists to refuse.
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
    start = s.index('case "${NODE_DNS_PATH:-}" in')
    end = s.index("# 19. Off-site backup freshness.")
except ValueError:
    sys.exit("could not locate the LAN DNS block in run-check.sh — markers moved")
blk = s[start:end]
if "dig +short" not in blk:
    sys.exit("located a block, but it does not resolve anything — wrong slice")
(work / "block.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

FAILED=0
run() {  # $1=NODE_DNS_PATH  $2=what dig returns  $3=expected row prefix
  NODE_DNS_PATH="$1"; SECRET_DOMAIN="example.cc"; DIG_OUT="$2"; OUT=""
  record() { OUT="[$1] $2"; }
  dig() { [[ -n "$DIG_OUT" ]] && echo "$DIG_OUT"; return 0; }
  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  local got="${OUT:-<no row>}"
  if [[ "$got" == "$3"* ]]; then
    printf 'PASS  flag=%-7s dig=%-14s -> %s\n' "${1:-<empty>}" "${2:-<silence>}" "$got"
  else
    printf 'FAIL  flag=%-7s dig=%-14s -> %s\n        expected %s...\n' \
      "${1:-<empty>}" "${2:-<silence>}" "$got" "$3"
    FAILED=$((FAILED + 1))
  fi
}

# The probe itself, where it is valid.
run lan    10.9.1.254   "[ok]"
run lan    192.168.1.20 "[ok]"
run lan    ""           "[fail]"
run lan    104.21.5.6   "[warn]"

# Where it is not valid, and where nothing is known. Both must SAY so. Emitting
# no row was the previous behaviour for these, and no row reads exactly like a
# passing one — which is the whole reason this file exists.
run public ""           "[skip]"
run public 10.9.1.254   "[skip]"
run ""     ""           "[skip]"
run ""     10.9.1.254   "[skip]"

# The old value domain must not quietly do anything. `true` reaching this block
# at all would mean jg-cluster-template is still emitting the boolean, which
# takes the whole Secret down before the script ever runs (#16) — but if it ever
# does arrive, it has to land in "not measured", never in a silent pass and
# never in a probe result.
run true   10.9.1.254   "[skip]"
run false  10.9.1.254   "[skip]"

echo
if (( FAILED )); then
  echo "$FAILED case(s) failed."
  echo "A silent row reads like a passing one; an alarm on a healthy LAN trains"
  echo "the reader to ignore the channel carrying seventeen other checks."
  exit 1
fi
echo "ok — 10 cases match"
