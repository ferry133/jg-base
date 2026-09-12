#!/usr/bin/env bash
# Assert what daily-check's GITHUB TOKEN EXPIRY row (check 25) emits.
#
# ferry133/jg-base#99. factory holds a fine-grained PAT that creates each
# customer's cluster repo. Nothing watched its expiry: presence was checked,
# validity was not — the shape fleet-ops#11 closed for Omni keys. This one
# breaks worse. An expired Omni key breaks a diagnostic tool; this breaks
# provisioning halfway through creating a repo, ticket already open.
#
# The acceptance its requester wrote (FO-openspec [8e8ef1], on #99):
#   1. the row's OWN OUTPUT says it has no key id — not just a comment;
#   2. it prints the date it compared (the in-cluster date is a copy of
#      fleet-ops' ledger, and a copy must print itself so drift is visible);
#   3. empty or absent annotation is skip, never ok;
#   4. negative controls for expired, inside 7 days, inside 30 days, and an
#      unparseable date reported as unknown, not fine;
#   5. (jgct side) a token without a date fails the render.
# 1 to 4 are asserted here, per case and again across cases.
#
# epoch_of runs for real (GNU date, as in the production image).
#
# Usage: scripts/check-github-token-expiry-row.sh
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
    start = s.index("# 25. GitHub token expiry")
    end = s.index('echo "==> Compiling report"')
except ValueError:
    sys.exit("could not locate check 25 in run-check.sh — markers moved")
blk = s[start:end]
for must, why in (("get deployments,statefulsets -A", "no longer enumerates workloads cluster-wide"),
                  ("epoch_of", "no longer parses the date through epoch_of"),
                  ("GHT_CAVEAT", "no longer carries the caveat")):
    if must not in blk:
        sys.exit(f"located a check-25 block that {why} — wrong slice, or the row lost it")
(work / "block.sh").write_text(blk)
m = re.search(r"^epoch_of\(\) \{\n.*?^\}\n", s, re.S | re.M)
if not m:
    sys.exit("could not extract epoch_of() from run-check.sh")
(work / "epoch_of.sh").write_text(m.group(0))
a = re.search(r'^GHT_ANN="([^"]+)"', blk, re.M)
if not a:
    sys.exit("could not read GHT_ANN from check 25")
(work / "ann").write_text(a.group(1))
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }
ANN="$(cat "$WORK/ann")"

NOW=1767225600   # 2026-01-01T00:00:00Z
FAILED=0
declare -A OUTS=() DATES=()

wl() { # $1=ns $2=name $3=annotation value ("-" = no annotations at all)
  if [[ "$3" == "-" ]]; then
    printf '{"kind":"Deployment","metadata":{"namespace":"%s","name":"%s"}}' "$1" "$2"
  else
    printf '{"kind":"Deployment","metadata":{"namespace":"%s","name":"%s","annotations":{"%s":"%s"}}}' "$1" "$2" "$ANN" "$3"
  fi
}

run() { # $1=label $2=items body (or ERR) $3=expected output
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
  if [[ "$got" == "$want" ]]; then
    printf 'PASS  %-16s -> %s\n' "$label" "$(echo "$got" | head -1 | cut -c1-78)"
  else
    printf 'FAIL  %-16s\n  got:\n%s\n  want:\n%s\n' "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

M="GitHub token expiry measured"
CAV_KEYID="no key id"

run list-error ERR \
"[warn] GitHub token expiry — could not list Deployments/StatefulSets cluster-wide (RBAC or API error) — this row measured nothing"

run none "$(wl factory factory ""),$(wl default echo -)" \
"[skip] GitHub token expiry — no workload on this cluster records a GitHub token expiry, so this row measured nothing — a token held without a recorded date is invisible here"

# 575 days counted by hand (365 to 2027-01-01, then 31+28+31+30+31+30+29).
DATES[healthy]="2027-07-30"
run healthy "$(wl factory factory 2027-07-30)" \
"[ok] GitHub token factory/factory expires 2027-07-30 (575d left)
[ok] $M: 1 — $(sed -n 's/^GHT_CAVEAT="\(.*\)"$/\1/p' "$WORK/block.sh")"

DATES[expired]="2025-12-31"
run expired "$(wl factory factory 2025-12-31)" \
"[warn] GitHub token factory/factory expired 2025-12-31 — the recorded expiry has passed — if that date is right, the next repo this workload tries to create fails
[ok] $M: 1 — $(sed -n 's/^GHT_CAVEAT="\(.*\)"$/\1/p' "$WORK/block.sh")"

DATES[inside-7d]="2026-01-04"
run inside-7d "$(wl factory factory 2026-01-04)" \
"[warn] GitHub token factory/factory expires 2026-01-04 — 3d left — reissue now (fine-grained PAT, no key id: match it by name and expiry)
[ok] $M: 1 — $(sed -n 's/^GHT_CAVEAT="\(.*\)"$/\1/p' "$WORK/block.sh")"

DATES[inside-30d]="2026-01-21"
run inside-30d "$(wl factory factory 2026-01-21)" \
"[warn] GitHub token factory/factory expires 2026-01-21 — 20d left — schedule the reissue
[ok] $M: 1 — $(sed -n 's/^GHT_CAVEAT="\(.*\)"$/\1/p' "$WORK/block.sh")"

DATES[exactly-30d]="2026-01-31"
run exactly-30d "$(wl factory factory 2026-01-31)" \
"[ok] GitHub token factory/factory expires 2026-01-31 (30d left)
[ok] $M: 1 — $(sed -n 's/^GHT_CAVEAT="\(.*\)"$/\1/p' "$WORK/block.sh")"

# Right shape, impossible day: only the real epoch_of refuses this.
DATES[bad-day]="2027-02-30"
run bad-day "$(wl factory factory 2027-02-30)" \
"[warn] GitHub token factory/factory — cannot parse recorded expiry '2027-02-30' (want YYYY-MM-DD) — this token's expiry is unknown, not fine
[ok] $M: 1 — $(sed -n 's/^GHT_CAVEAT="\(.*\)"$/\1/p' "$WORK/block.sh")"

# A shape GNU date ACCEPTS and misreads: 2027-07-3 is July 3rd, not the 30th.
DATES[bad-shape]="2027-07-3"
run bad-shape "$(wl factory factory 2027-07-3)" \
"[warn] GitHub token factory/factory — cannot parse recorded expiry '2027-07-3' (want YYYY-MM-DD) — this token's expiry is unknown, not fine
[ok] $M: 1 — $(sed -n 's/^GHT_CAVEAT="\(.*\)"$/\1/p' "$WORK/block.sh")"

echo

# ── cross-case: the acceptance, restated against outputs ───────────────────
# 1. The row states its own weakness where it is read.
for l in "${!DATES[@]}"; do
  if [[ "${OUTS[$l]}" != *"$CAV_KEYID"* ]]; then
    echo "FAIL  '$l' measured a token but its output never says the PAT has no key id (#99 condition 1)"
    FAILED=$((FAILED + 1))
  fi
done
# 2. Every row about a token prints the date it compared.
for l in "${!DATES[@]}"; do
  while IFS= read -r row; do
    [[ "$row" == *"GitHub token "*"/"* ]] || continue
    [[ "$row" == *"${DATES[$l]}"* ]] || {
      echo "FAIL  '$l' row does not print the date it compared (#99 condition 2): $row"
      FAILED=$((FAILED + 1)); }
  done <<< "${OUTS[$l]}"
done
# 3. Could-not-measure is never ok.
for l in list-error none bad-day bad-shape; do
  if [[ "$(echo "${OUTS[$l]}" | head -1)" == "[ok]"* ]]; then
    echo "FAIL  '$l' measured nothing and reported ok (#99 condition 3)"
    FAILED=$((FAILED + 1))
  fi
done
# 4. The windows read apart, and nothing ever fails (FAIL_COUNT gates the
#    dead-man ping, and an expired token is not a dead cluster).
[[ "${OUTS[expired]}" == *"expired 2025-12-31"* ]] \
  || { echo "FAIL  an expired token's row does not say 'expired'"; FAILED=$((FAILED + 1)); }
[[ "${OUTS[inside-7d]}" == *"reissue now"* && "${OUTS[inside-7d]}" != *"schedule the reissue"* ]] \
  || { echo "FAIL  inside 7 days does not read 'reissue now', distinct from the 30-day window"; FAILED=$((FAILED + 1)); }
[[ "${OUTS[inside-30d]}" == *"schedule the reissue"* && "${OUTS[inside-30d]}" != *"reissue now"* ]] \
  || { echo "FAIL  inside 30 days does not read 'schedule the reissue', distinct from the 7-day window"; FAILED=$((FAILED + 1)); }
for l in "${!OUTS[@]}"; do
  if [[ "${OUTS[$l]}" == *"[fail]"* ]]; then
    echo "FAIL  '$l' recorded fail — row 25 must never fail: FAIL_COUNT marks the whole cluster Down"
    FAILED=$((FAILED + 1))
  fi
done
if [[ "$(echo "${OUTS[healthy]}" | head -1)" != "[ok]"* ]]; then
  echo "FAIL  a valid far-future token did not read ok — a row that rings at every input carries no information"
  FAILED=$((FAILED + 1))
fi

# ── the contract no case can see: every PAT holder carries the annotation ──
python3 - "$ROOT" "$ANN" <<'PY' || FAILED=$((FAILED + 1))
import re, sys
from pathlib import Path
root, ann = Path(sys.argv[1]), sys.argv[2]
files = sorted(root.glob("kubernetes/**/*.yaml"))
# Which Secret keys hold a GitHub PAT, derived from the variable that fills
# them. `*_GITHUB_TOKEN` only: GITHUB_WEBHOOK_TOKEN is flux-instance's webhook
# HMAC, not a PAT, and has no expiry to record — excluded deliberately, not
# missed.
held = {}
for f in files:
    for doc in re.split(r"^---\s*$", f.read_text(), flags=re.M):
        if not re.search(r"^kind:\s*Secret\s*$", doc, re.M):
            continue
        name = re.search(r"^metadata:\s*\n(?:\s+.*\n)*?\s+name:\s*(\S+)", doc, re.M)
        for m in re.finditer(r'^\s+([A-Za-z0-9_]+):\s*"?\$\{([A-Z0-9_]*_GITHUB_TOKEN)(?::-[^}]*)?\}"?\s*$', doc, re.M):
            held[(name.group(1) if name else "?", m.group(1))] = m.group(2)
if not held:
    sys.exit("CANNOT MEASURE: no Secret key is filled from a *_GITHUB_TOKEN variable; "
             "factory-credentials/githubToken is one, so the derivation is broken")
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
print(f"PAT holders derived from Secrets: {', '.join(f'{s}/{k}' for s, k in sorted(held))}")
for c in consumers:
    print(f"  consumer: {c}")
if not consumers:
    sys.exit("CANNOT MEASURE: no workload mounts the PAT; factory does, so the match is broken")
if bad:
    print("FAIL  a workload holds a GitHub PAT but check 25 cannot see its expiry:")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print("PASS  every PAT consumer carries the expiry annotation")
PY

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — ${#OUTS[@]} cases match; the no-key-id caveat and the compared date travel with every measurement; unmeasured != ok; never fails"
