#!/usr/bin/env bash
# Assert what daily-check's rows 2 (Flux Kustomizations) and 15 (GitRepository
# sources) emit when the list cannot be read, and when it can.
#
# ferry133/jg-base#215: both rows ran `kubectl get ... -o json 2>/dev/null`,
# never read the exit status, and judged only whether the not-Ready list was
# empty. A failed query gives an empty list, so RBAC loss or an API error
# printed the same ✅ as "all Ready". split-extras 5.4 gated on these two rows
# being green, and that green could not be taken as a reading.
#
# The cases that must not regress are the "could not measure" ones: a failed
# kubectl, output that is not a list, and a list without flux-system/
# flux-system must never render ok. The healthy and not-Ready cases exist so
# those cannot be met by a row that warns at everything.
#
# It sources the real blocks out of the ConfigMap rather than restating them,
# like check-backup-cronjob-row.sh: a copy here would drift and keep passing.
#
# Usage: scripts/check-flux-rows-unmeasured.sh   (exit 0 if every case matches)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null || { echo "jq required (ships on the CI runner image)"; exit 1; }

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
    helper = s[s.index("# Lists one Flux kind"):s.index("# 2. Flux Kustomizations")]
    row2 = s[s.index("# 2. Flux Kustomizations"):s.index("# 3. HelmReleases")]
    row15 = s[s.index("# 15. GitRepository sources"):s.index("# 16. LoadBalancer")]
except ValueError:
    sys.exit("could not locate flux_list / row 2 / row 15 in run-check.sh — markers moved")
if "flux_list()" not in helper:
    sys.exit("located a helper slice without flux_list() — wrong slice")
for name, blk, kind in (("row 2", row2, "kustomization"), ("row 15", row15, "gitrepository")):
    if f"flux_list {kind}" not in blk:
        sys.exit(f"{name} does not call flux_list {kind} — #215 is gone")
    if "2>/dev/null)" in blk and "kubectl get" in blk:
        sys.exit(f"{name} queries kubectl with stderr discarded again — #215's shape")
(work / "helper.sh").write_text(helper)
(work / "row2.sh").write_text(row2)
(work / "row15.sh").write_text(row15)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

FAILED=0
declare -A SEEN=()

# One Flux object. $1=ns $2=name $3=Ready status $4=suspend (default false)
obj() {
  printf '{"metadata":{"namespace":"%s","name":"%s"},"spec":{"suspend":%s},"status":{"conditions":[{"type":"Ready","status":"%s"}]}}' \
    "$1" "$2" "${4:-false}" "$3"
}
ROOT_OBJ="$(obj flux-system flux-system True)"

# $1=row (2|15)  $2=label  $3=mode  $4=payload  $5=expected row
#   mode ok   -> kubectl prints $4 as stdout, exits 0
#   mode err  -> kubectl prints $4 on stderr, exits 1
run() {
  local row="$1" label="$2" mode="$3" payload="$4" want="$5"
  ROWS=()
  record() { ROWS+=("[$1] $2${3:+ — $3}"); }
  if [[ "$mode" == "err" ]]; then
    kubectl() { echo "$payload" >&2; return 1; }
  else
    kubectl() { printf '%s\n' "$payload"; }
  fi
  # run-check.sh runs under `set -uo pipefail`, without -e: a jq that fails on
  # unparseable input inside `$(...)` does not end the script there, so it
  # must not end this harness either.
  set +e
  # shellcheck disable=SC1091
  source "$WORK/helper.sh"
  # shellcheck disable=SC1090
  source "$WORK/row${row}.sh" 2>/dev/null
  set -e
  unset -f kubectl record flux_list 2>/dev/null || true

  local got; got="$(printf '%s\n' "${ROWS[@]:-<no row>}")"
  SEEN["$row/$label"]="$got"
  if [[ "$got" == "$want" ]]; then
    printf 'PASS  row %-2s %-18s -> %s\n' "$row" "$label" "$(echo "$got" | head -1 | cut -c1-70)"
  else
    printf 'FAIL  row %-2s %-18s\n  got:\n%s\n  want:\n%s\n' "$row" "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

FORBIDDEN='Error from server (Forbidden): kustomizations.kustomize.toolkit.fluxcd.io is forbidden'
GFORBIDDEN='Error from server (Forbidden): gitrepositories.source.toolkit.fluxcd.io is forbidden'

# ── row 2 ───────────────────────────────────────────────────────────────────
run 2 healthy ok "{\"items\":[$ROOT_OBJ,$(obj flux-system cluster-apps True)]}" \
"[ok] Flux Kustomizations all Ready"

run 2 not-ready ok "{\"items\":[$ROOT_OBJ,$(obj flux-system cluster-apps False)]}" \
"[fail] Flux Kustomizations — Not Ready: flux-system/cluster-apps "

run 2 suspended-stale ok "{\"items\":[$ROOT_OBJ,$(obj flux-system old False true)]}" \
"[warn] Flux Kustomizations — suspended while not Ready, so this status is frozen and will not clear itself: flux-system/old "

run 2 rbac-lost err "$FORBIDDEN" \
"[warn] Flux Kustomizations — could not list kustomization cluster-wide (kubectl rc=1: $FORBIDDEN) — this row measured nothing"

run 2 empty-stdout ok "" \
"[warn] Flux Kustomizations — kubectl get kustomization returned no item list — this row measured nothing"

run 2 not-json ok "$FORBIDDEN" \
"[warn] Flux Kustomizations — kubectl get kustomization returned no item list — this row measured nothing"

run 2 empty-list ok '{"items":[]}' \
"[warn] Flux Kustomizations — the kustomization list has no flux-system/flux-system, which every cluster has (0 items), so it is not this cluster's list — this row measured nothing"

run 2 no-root ok "{\"items\":[$(obj default other True)]}" \
"[warn] Flux Kustomizations — the kustomization list has no flux-system/flux-system, which every cluster has (1 items), so it is not this cluster's list — this row measured nothing"

# ── row 15 ──────────────────────────────────────────────────────────────────
run 15 healthy ok "{\"items\":[$ROOT_OBJ,$(obj flux-system jg-base True)]}" \
"[ok] Flux GitRepository sources Ready"

run 15 not-ready ok "{\"items\":[$ROOT_OBJ,$(obj flux-system jg-extras False)]}" \
"[fail] Flux GitRepository sources — flux-system/jg-extras "

run 15 rbac-lost err "$GFORBIDDEN" \
"[warn] Flux GitRepository sources — could not list gitrepository cluster-wide (kubectl rc=1: $GFORBIDDEN) — this row measured nothing"

run 15 empty-stdout ok "" \
"[warn] Flux GitRepository sources — kubectl get gitrepository returned no item list — this row measured nothing"

run 15 empty-list ok '{"items":[]}' \
"[warn] Flux GitRepository sources — the gitrepository list has no flux-system/flux-system, which every cluster has (0 items), so it is not this cluster's list — this row measured nothing"

echo

# ── cross-case assertions ───────────────────────────────────────────────────
# Per-case expectations can all be edited to match a broken row at once. These
# say the one thing #215 is about in a form an edit has to contradict.
for key in 2/rbac-lost 2/empty-stdout 2/not-json 2/empty-list 2/no-root \
           15/rbac-lost 15/empty-stdout 15/empty-list; do
  if [[ "${SEEN[$key]}" == *"[ok]"* ]]; then
    echo "FAIL  row ${key%%/*} case ${key#*/} rendered ok. That is #215: a list that"
    echo "      could not be read printed the same ✅ as 'all Ready'."
    FAILED=$((FAILED + 1))
  fi
done
for row in 2 15; do
  if [[ "${SEEN[$row/healthy]}" != *"[ok]"* ]] || [[ "${SEEN[$row/not-ready]}" != *"[fail]"* ]]; then
    echo "FAIL  row $row: the healthy case is not ok or the not-Ready case is not fail,"
    echo "      so the cases above could be met by a row that warns at everything."
    FAILED=$((FAILED + 1))
  fi
done

if (( FAILED > 0 )); then
  echo "FAILED: $FAILED case(s)"
  exit 1
fi
echo "ok — every case matches; no unreadable list renders ok on row 2 or 15"
