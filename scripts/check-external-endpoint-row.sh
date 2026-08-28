#!/usr/bin/env bash
# Assert what daily-check's external-endpoint row emits, per input.
#
# The row this guards was green on a cluster with no public DNS record at all —
# reachable from nowhere outside, reported OK (ferry133/jg-base#43). It was
# also green after the fault was repaired, so its two states were
# indistinguishable and it never carried information.
#
# The case that matters most here is `no public record -> [fail]`. That is the
# exact input that used to render as a pass, and #43's acceptance condition was
# to see this check go red rather than to be told it would. This file is that
# demonstration in executable form, so it stays true after the next edit.
#
# Like check-lan-dns-row.sh, it sources the real block out of the ConfigMap
# rather than restating its logic. A copy here would drift, and the copy that
# drifts keeps passing.
#
# Run by CI: the `scripts` job in .github/workflows/flux-local.yaml (#32).
#
# Usage: scripts/check-external-endpoint-row.sh   (exit 0 if every case matches)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v yq >/dev/null || {
  echo "yq required. CI installs it pinned (version + sha256) in the"
  echo "'scripts' job of .github/workflows/flux-local.yaml; match that"
  echo "version locally rather than picking one."
  exit 1
}
command -v jq >/dev/null || { echo "jq required (the block under test parses DoH JSON with it)"; exit 1; }
yq -r '.data."run-check.sh"' "$CM" > "$WORK/run-check.sh"

# Slice out the block under test. Failing to find it must abort, never silently
# test an empty file — that is the shape this whole script exists to prevent.
python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1])
s = (work / "run-check.sh").read_text()
try:
    start = s.index("# 11. External endpoint reachability")
    end = s.index("# 12. NAS connectivity")
except ValueError:
    sys.exit("could not locate the external-endpoint block in run-check.sh — markers moved")
blk = s[start:end]
for needle in ("dns-query", "--resolve", "ENDPOINT_UNMEASURED"):
    if needle not in blk:
        sys.exit(f"located a block, but it lacks {needle!r} — wrong slice or the check regressed")
(work / "block.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

FAILED=0
# $1=label  $2=DoH behaviour  $3=probe HTTP code  $4=expected row prefix
run() {
  # DOH_MODE, not `doh`: the block under test uses `doh` as its own loop
  # variable, and a collision made every case answer "no public record" —
  # including the ones that then read as PASS for the wrong reason.
  local label="$1" DOH_MODE="$2" probe="$3" want="$4"
  ENDPOINTS_TO_PROBE="https://im.example.cc"; OUT=""
  record() { OUT="[$1] $2 ${3:-}"; }

  # Stand in for both curl roles: the DoH lookup and the forced-address probe.
  # Keyed on the argument list, so a change to how the block calls curl shows
  # up here as a miss rather than as a silent pass.
  curl() {
    local args="$*"
    if [[ "$args" == *dns-query* || "$args" == *dns.google* ]]; then
      case "$DOH_MODE" in
        unreachable) return 7 ;;                                   # curl exit 7
        nxdomain)    echo '{"Status":3}' ;;                        # no Answer
        private)     echo '{"Status":0,"Answer":[{"type":1,"data":"10.9.1.20"}]}' ;;
        public)      echo '{"Status":0,"Answer":[{"type":1,"data":"104.21.5.6"}]}' ;;
        cname_only)  echo '{"Status":0,"Answer":[{"type":5,"data":"x.cdn.net."}]}' ;;
      esac
      return 0
    fi
    # the forced-address probe
    [[ "$args" == *--resolve* ]] || { echo "PROBE DID NOT USE --resolve" >&2; return 1; }
    echo "$probe"
    return 0
  }
  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  local got="${OUT:-<no row>}"
  if [[ "$got" == "$want"* ]]; then
    printf 'PASS  %-28s -> %s\n' "$label" "${got:0:96}"
  else
    printf 'FAIL  %-28s -> %s\n        expected %s...\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

# The one #43 is about: no public record anywhere. This used to render `ok`.
run "no public record"        nxdomain    ""    "[fail]"
# A public address that answers is the only thing that may read as a pass.
run "public + 200"            public      "200" "[ok]"
run "public + 301"            public      "301" "[ok]"
# A public address that does not answer is a real failure, not a silence.
run "public + 000"            public      "000" "[fail]"
run "public + 502"            public      "502" "[fail]"
# Not measured, and it must SAY not-measured rather than pass.
run "no resolver reachable"   unreachable ""    "[skip]"
run "public record is RFC1918" private    ""    "[skip]"
# Only A records count; a CNAME-only answer leaves nothing to force an address
# to, so it is not a pass either.
run "CNAME only, no A"        cname_only  ""    "[fail]"

echo
if (( FAILED )); then
  echo "$FAILED case(s) failed."
  echo "A row that reads OK from inside the cluster while nothing outside can"
  echo "reach the name is worse than no row: it is consulted and believed."
  exit 1
fi
echo "ok — 8 cases match"
