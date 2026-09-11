#!/usr/bin/env bash
# Assert what daily-check's OMNI SA KEY EXPIRY row (check 24) emits.
#
# ferry133/fleet-ops#11: talos-mcp's guard checks that its Omni key is
# *filled*, not that it is *valid*. An expired key passes that check, the pod
# stays Running, and the failure is a talosctl auth error at the moment an
# agent calls a tool. The expiry is known at issuance, so check 24 reads the
# date recorded then — an annotation on each workload holding a key.
#
# The acceptance its opener agreed to (FO-handler [f92b04], fleet-ops#11):
#   * valid keys go green AND print their dates;
#   * a date already past is red; a date inside seven days is fail;
#   * the uncovered cases (revoked key, malformed key with a future date) are
#     named in the ROW'S OWN OUTPUT, not only in the issue.
# Those three are asserted again below as cross-case checks, because
# per-case expectations can all be edited to match a broken row in one pass.
#
# It also asserts the other half of the contract, which no case can see: every
# workload in this repo that mounts a Secret key carrying an Omni SA key must
# carry the annotation this row reads. The consumer list is DERIVED from the
# Secrets, not typed here — a list typed from memory misses exactly the
# consumer nobody remembered.
#
# epoch_of runs for real (GNU date, as in the production image). A stubbed
# parser would pass while the real one refused every date.
#
# Sources the real block out of the ConfigMap rather than restating it: a copy
# here would drift, and the copy that drifts keeps passing.
#
# Usage: scripts/check-omni-key-expiry-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null || { echo "jq required (ships on the CI runner image)"; exit 1; }

GNUDATE=""
for c in date gdate; do
  if command -v "$c" >/dev/null && "$c" -u -d 2027-07-30T00:00:00Z +%s >/dev/null 2>&1; then
    GNUDATE="$(command -v "$c")"; break
  fi
done
if [[ -z "$GNUDATE" ]]; then
  echo "CANNOT MEASURE: no GNU date on PATH (tried date, gdate). This guard runs"
  echo "epoch_of for real, as the production image does; it is not a pass."
  exit 2
fi

# Extract data."run-check.sh" without yq (same extractor as the backup guard).
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
import re, sys
from pathlib import Path
work = Path(sys.argv[1])
s = (work / "run-check.sh").read_text()
try:
    start = s.index("# 24. Omni service-account key expiry")
    end = s.index('echo "==> Compiling report"')
except ValueError:
    sys.exit("could not locate check 24 in run-check.sh — markers moved")
blk = s[start:end]
for must, why in (("get deployments,statefulsets -A", "no longer enumerates workloads cluster-wide"),
                  ("epoch_of", "no longer parses the date through epoch_of"),
                  ("OMNI_CAVEAT", "no longer carries the caveat")):
    if must not in blk:
        sys.exit(f"located a check-24 block that {why} — wrong slice, or the row lost it")
(work / "block.sh").write_text(blk)
m = re.search(r"^epoch_of\(\) \{\n.*?^\}\n", s, re.S | re.M)
if not m:
    sys.exit("could not extract epoch_of() from run-check.sh")
(work / "epoch_of.sh").write_text(m.group(0))
a = re.search(r'^OMNI_ANN="([^"]+)"', blk, re.M)
if not a:
    sys.exit("could not read OMNI_ANN from check 24")
(work / "ann").write_text(a.group(1))
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

ANN="$(cat "$WORK/ann")"
# The opener's wording (fleet-ops#11, condition A). Typed here on purpose: if
# the row's caveat is edited away or softened, this is what notices.
CAVEAT="expiry read from the recorded date, not from the key — a revoked or malformed key with a future date still reads green here"

NOW=1767225600   # 2026-01-01T00:00:00Z
FAILED=0
declare -A SEEN=()      # label -> distinct levels seen
declare -A OUTS=()      # label -> full output
declare -A DATES=()     # label -> dates in the fixture, '|'-separated

# One workload. $1=ns $2=name $3=annotation value ("-" = no annotations at all)
wl() {
  if [[ "$3" == "-" ]]; then
    printf '{"kind":"Deployment","metadata":{"namespace":"%s","name":"%s"}}' "$1" "$2"
  else
    printf '{"kind":"Deployment","metadata":{"namespace":"%s","name":"%s","annotations":{"%s":"%s"}}}' "$1" "$2" "$ANN" "$3"
  fi
}

# $1=label $2=items body (or ERR) $3=expected output (one row per line)
run() {
  local label="$1" items="$2" want="$3"
  ROWS=()
  record() { ROWS+=("[$1] $2${3:+ — $3}"); }
  date() { if [[ "$*" == "-u +%s" ]]; then echo "$NOW"; else "$GNUDATE" "$@"; fi; }
  if [[ "$items" == "ERR" ]]; then
    kubectl() { echo 'Error from server (Forbidden)' >&2; return 1; }
  else
    kubectl() {
      [[ "$*" == "get deployments,statefulsets -A -o json" ]] || { echo "UNEXPECTED kubectl: $*" >&2; return 1; }
      printf '{"items":[%s]}\n' "$items"
    }
  fi
  # shellcheck disable=SC1091
  source "$WORK/epoch_of.sh"
  # shellcheck disable=SC1091
  source "$WORK/block.sh"
  unset -f kubectl date record epoch_of 2>/dev/null || true

  local got; got="$(printf '%s\n' "${ROWS[@]:-<no row>}")"
  OUTS["$label"]="$got"
  SEEN["$label"]="$(printf '%s\n' "${ROWS[@]:-}" | sed -n 's/^\[\([a-z]*\)\].*/\1/p' | sort -u | tr '\n' ' ')"
  if [[ "$got" == "$want" ]]; then
    printf 'PASS  %-18s -> %s\n' "$label" "$(echo "$got" | head -1 | cut -c1-80)"
  else
    printf 'FAIL  %-18s\n  got:\n%s\n  want:\n%s\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

M="Omni SA key expiry measured"

# ── could not measure: never ok ──────────────────────────────────────────────
run list-error ERR \
"[warn] Omni SA key expiry — could not list Deployments/StatefulSets cluster-wide (RBAC or API error) — this row measured nothing"

run none "$(wl claudecode im ""),$(wl default echo -)" \
"[skip] Omni SA key expiry — no workload on this cluster records an Omni service-account key expiry, so this row measured nothing — a key held without a recorded date is invisible here"

# ── positive control: a valid key, far out, prints its date ─────────────────
# 575 days is counted by hand (365 to 2027-01-01, then 31+28+31+30+31+30+29),
# not by the code under test.
DATES[healthy]="2027-07-30"
run healthy "$(wl claudecode im 2027-07-30)" \
"[ok] Omni SA key claudecode/im expires 2027-07-30 (575d left)
[ok] $M: 1 — $CAVEAT"

# ── the two negative controls the opener wrote ─────────────────────────────
DATES[expired]="2025-12-31"
run expired "$(wl claudecode im 2025-12-31)" \
"[fail] Omni SA key claudecode/im expired 2025-12-31 — the recorded expiry has passed — if that date is right, every Omni call from this workload now fails
[ok] $M: 1 — $CAVEAT"

DATES[inside-7d]="2026-01-04"
run inside-7d "$(wl factory factory 2026-01-04)" \
"[fail] Omni SA key factory/factory expires 2026-01-04 — 3d left — reissue now (fleet-ops handover-inventory.md)
[ok] $M: 1 — $CAVEAT"

# ── boundaries, so "within seven days" means one thing ──────────────────────
DATES[expires-today]="2026-01-01"
run expires-today "$(wl claudecode im 2026-01-01)" \
"[fail] Omni SA key claudecode/im expired 2026-01-01 — the recorded expiry has passed — if that date is right, every Omni call from this workload now fails
[ok] $M: 1 — $CAVEAT"

DATES[exactly-7d]="2026-01-08"
run exactly-7d "$(wl claudecode im 2026-01-08)" \
"[warn] Omni SA key claudecode/im expires 2026-01-08 — 7d left — schedule the reissue
[ok] $M: 1 — $CAVEAT"

DATES[inside-30d]="2026-01-21"
run inside-30d "$(wl factory factory 2026-01-21)" \
"[warn] Omni SA key factory/factory expires 2026-01-21 — 20d left — schedule the reissue
[ok] $M: 1 — $CAVEAT"

DATES[exactly-30d]="2026-01-31"
run exactly-30d "$(wl claudecode im 2026-01-31)" \
"[ok] Omni SA key claudecode/im expires 2026-01-31 (30d left)
[ok] $M: 1 — $CAVEAT"

# ── unknown is said as unknown ─────────────────────────────────────────────
# Shape refused before parsing. The fixture has to be one GNU date ACCEPTS,
# or this case cannot tell the anchor from no anchor: `2027-07-3` (a truncated
# 30) parses as July 3rd — measured — and would read green here, 575 days out,
# for a key that expires 27 days earlier. ("next month" was the first fixture;
# the T00:00:00Z suffix already makes GNU date refuse it, so removing the
# anchor left this case passing. Caught by mutation, not by reading.)
DATES[bad-shape]="2027-07-3"
run bad-shape "$(wl claudecode im 2027-07-3)" \
"[warn] Omni SA key claudecode/im — cannot parse recorded expiry '2027-07-3' (want YYYY-MM-DD) — this key's expiry is unknown, not fine
[ok] $M: 1 — $CAVEAT"

# Right shape, impossible day: only the REAL epoch_of can refuse this one.
DATES[bad-day]="2027-02-30"
run bad-day "$(wl claudecode im 2027-02-30)" \
"[warn] Omni SA key claudecode/im — cannot parse recorded expiry '2027-02-30' (want YYYY-MM-DD) — this key's expiry is unknown, not fine
[ok] $M: 1 — $CAVEAT"

# ── the shape of jcom + a talos key: two holders, each judged on its own ────
DATES[mixed]="2027-07-30|2026-01-04"
run mixed "$(wl claudecode im 2027-07-30),$(wl factory factory 2026-01-04),$(wl default echo -)" \
"[ok] Omni SA key claudecode/im expires 2027-07-30 (575d left)
[fail] Omni SA key factory/factory expires 2026-01-04 — 3d left — reissue now (fleet-ops handover-inventory.md)
[ok] $M: 2 — $CAVEAT"

echo

# ── cross-case: the acceptance, restated against outputs ────────────────────
for l in expired inside-7d expires-today; do
  if [[ "${SEEN[$l]}" != *fail* ]]; then
    echo "FAIL  '$l' did not fail — the opener's negative control (past / inside 7 days -> red) is gone"
    FAILED=$((FAILED + 1))
  fi
done
if [[ "${SEEN[healthy]}" != "ok " ]]; then
  echo "FAIL  a valid far-future key did not read ok — a row that rings at every input carries no information"
  FAILED=$((FAILED + 1))
fi
for l in list-error none bad-shape bad-day; do
  first="$(echo "${OUTS[$l]}" | head -1)"
  if [[ "$first" == "[ok]"* ]]; then
    echo "FAIL  '$l' measured nothing and reported ok — could-not-measure folded into pass"
    FAILED=$((FAILED + 1))
  fi
done
# Condition A: the caveat travels with every measurement.
for l in "${!DATES[@]}"; do
  if [[ "${OUTS[$l]}" != *"$CAVEAT"* ]]; then
    echo "FAIL  '$l' measured a key but its output does not carry the caveat (fleet-ops#11 condition A)"
    FAILED=$((FAILED + 1))
  fi
done
# Condition B: every row about a key prints the date it compared.
for l in "${!DATES[@]}"; do
  IFS='|' read -r -a ds <<< "${DATES[$l]}"
  while IFS= read -r row; do
    [[ "$row" == *"Omni SA key "*"/"* ]] || continue
    hit=0
    for d in "${ds[@]}"; do [[ "$row" == *"$d"* ]] && hit=1; done
    if (( ! hit )); then
      echo "FAIL  '$l' row does not print the date it compared (fleet-ops#11 condition B): $row"
      FAILED=$((FAILED + 1))
    fi
  done <<< "${OUTS[$l]}"
done

# ── the contract no case can see: every holder carries the annotation ───────
python3 - "$ROOT" "$ANN" <<'PY' || FAILED=$((FAILED + 1))
import re, sys
from pathlib import Path
root, ann = Path(sys.argv[1]), sys.argv[2]
files = sorted(root.glob("kubernetes/**/*.yaml"))
# 1. Which Secret keys carry an Omni SA key: derived from the substitution
#    that fills them, so a new one is found without anyone listing it.
held = {}   # (secret name, data key) -> VAR
for f in files:
    text = f.read_text()
    for doc in re.split(r"^---\s*$", text, flags=re.M):
        if not re.search(r"^kind:\s*Secret\s*$", doc, re.M):
            continue
        name = re.search(r"^metadata:\s*\n(?:\s+.*\n)*?\s+name:\s*(\S+)", doc, re.M)
        for m in re.finditer(r'^\s+([A-Za-z0-9_]+):\s*"?\$\{([A-Z0-9_]*_SA_KEY)(?::-[^}]*)?\}"?\s*$', doc, re.M):
            held[(name.group(1) if name else "?", m.group(1))] = m.group(2)
if len(held) < 2:
    sys.exit(f"CANNOT MEASURE: found {len(held)} Secret key(s) filled from *_SA_KEY; expected at least talos-mcp-secret/saKey and factory-credentials/omniServiceAccountKey — the derivation is broken, not the repo clean")
# 2. Every file that mounts one of them must carry the annotation for it.
bad, consumers = [], []
for f in files:
    text = f.read_text()
    for (secret, key), var in held.items():
        if re.search(rf"name:\s*{re.escape(secret)}\s*\n\s+key:\s*{re.escape(key)}\b", text):
            rel = f.relative_to(root)
            consumers.append(f"{rel} ({secret}/{key})")
            want = f'{ann}: "${{{var}_EXPIRES:-}}"'
            if want not in text:
                bad.append(f"{rel}: mounts {secret}/{key} but lacks  {want}")
print(f"holders derived from Secrets: {', '.join(f'{s}/{k}' for s, k in sorted(held))}")
for c in consumers:
    print(f"  consumer: {c}")
if len(consumers) < 2:
    sys.exit("CANNOT MEASURE: fewer than two consumers found — im and factory both mount one; the match is broken")
if bad:
    print("FAIL  a workload holds an Omni SA key but check 24 cannot see its expiry:")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print("PASS  every consumer carries the expiry annotation")
PY

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — ${#OUTS[@]} cases match; past and inside-7d fail; unmeasured != ok; caveat and dates on every measured row"
