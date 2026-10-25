#!/usr/bin/env bash
# Assert what daily-check rows 3, 4, 5, 8, 9, 10, 13, 14 and 16 emit when
# kubectl fails or answers with something that is not this cluster's list.
#
# ferry133/jg-base#217, the #215 shape in nine more rows: each ran
# `kubectl ... 2>/dev/null`, never read the exit status, and judged only
# whether the bad list was empty — so a failed query printed ✅ (row 13 printed
# no row at all). check-flux-rows-unmeasured.sh holds rows 2 and 15.
#
# The cases that must not regress are the unreadable ones never rendering ok.
# Healthy and bad cases exist per row so those cannot be met by a row that
# warns at everything; and the two rows whose empty answer is a real answer
# (5: no PVC, 9: no Warning event) must stay ok, so the fix cannot be met by
# treating every empty output as unmeasured.
#
# Sources the real blocks out of the ConfigMap, like check-backup-cronjob-row.sh.
#
# Usage: scripts/check-nine-rows-unmeasured.sh   (exit 0 if every case matches)

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
def cut(a, b):
    try:
        return s[s.index(a):s.index(b)]
    except ValueError:
        sys.exit(f"could not locate {a!r}..{b!r} in run-check.sh — markers moved")
helper = cut('# The same "could not measure" outcome for nine', "# 2. Flux Kustomizations")
if "kget()" not in helper or "kget_items()" not in helper:
    sys.exit("helper slice has no kget/kget_items — wrong slice")
(work / "helper.sh").write_text(helper)
rows = {
    "3": ("# 3. HelmReleases", "# 4. Pod restarts"),
    "4": ("# 4. Pod restarts", "# 5. PVCs all Bound"),
    "5": ("# 5. PVCs all Bound", "# 6. Backup CronJobs"),
    "8": ("# 8. TLS certificates", "# 9. Warning events"),
    "9": ("# 9. Warning events", "# 10. Cloudflare tunnel"),
    "10": ("# 10. Cloudflare tunnel", "# 11. External endpoint"),
    "13": ("# 13. Node resource usage", "# 14. Node disk pressure"),
    "14": ("# 14. Node disk pressure", "# 15. GitRepository sources"),
    "16": ("# 16. LoadBalancer address", "# 17. Discovered LAN"),
}
for row, (a, b) in rows.items():
    blk = cut(a, b)
    if "kget" not in blk:
        sys.exit(f"row {row} does not call kget — #217 is gone")
    for ln in blk.splitlines():
        if ln.lstrip().startswith("#"):
            continue
        if "$(kubectl" in ln and "2>/dev/null" in ln:
            sys.exit(f"row {row} queries kubectl with stderr discarded again — #217's shape: {ln.strip()}")
    (work / f"row{row}.sh").write_text(blk)
PY

bash -n "$WORK/run-check.sh" || { echo "run-check.sh does not parse"; exit 1; }

FAILED=0
declare -A SEEN=()

# $1=row  $2=label  $3=mode  $4=text payload  $5=json payload  $6=expected rows
#   mode ok  -> kubectl prints $5 when -o json is asked for, else $4; exits 0
#   mode err -> every kubectl call writes Forbidden on stderr and exits 1
run() {
  local row="$1" label="$2" mode="$3" text="$4" json="$5" want="$6"
  ROWS=()
  record() { ROWS+=("[$1] $2${3:+ — $3}"); }
  if [[ "$mode" == "err" ]]; then
    kubectl() { echo "Error from server (Forbidden): $2 is forbidden" >&2; return 1; }
  else
    kubectl() {
      case " $* " in
        *" -o json "*) printf '%s\n' "$json" ;;
        *)             [[ -n "$text" ]] && printf '%s\n' "$text"; return 0 ;;
      esac
    }
  fi
  # run-check.sh runs under `set -uo pipefail`, without -e.
  set +e
  # shellcheck disable=SC1091
  source "$WORK/helper.sh"
  # shellcheck disable=SC1090
  source "$WORK/row${row}.sh" 2>/dev/null
  set -e
  unset -f kubectl record kget kget_items 2>/dev/null || true

  local got; got="$(printf '%s\n' "${ROWS[@]:-<no row>}")"
  SEEN["$row/$label"]="$got"
  if [[ "$got" == "$want" ]]; then
    printf 'PASS  row %-2s %-14s -> %s\n' "$row" "$label" "$(echo "$got" | head -1 | cut -c1-72)"
  else
    printf 'FAIL  row %-2s %-14s\n  got:\n%s\n  want:\n%s\n' "$row" "$label" "$got" "$want"
    FAILED=$((FAILED + 1))
  fi
}

U=" — this row measured nothing"
NOW_PLUS_3D="$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)+d.timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
NOW_PLUS_90D="$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)+d.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
hr() { printf '{"metadata":{"namespace":"%s","name":"%s"},"status":{"conditions":[{"type":"Ready","status":"%s"}]}}' "$1" "$2" "$3"; }
pod() { printf '{"metadata":{"namespace":"%s","name":"%s"},"status":{"containerStatuses":[{"restartCount":0}]}}' "$1" "$2"; }
node() { printf '{"metadata":{"name":"%s"},"status":{"conditions":[{"type":"DiskPressure","status":"%s"}]}}' "$1" "$2"; }
svc() { printf '{"metadata":{"namespace":"%s","name":"%s"},"spec":{"type":"%s"},"status":{"conditions":[%s]}}' "$1" "$2" "$3" "${4:-}"; }

# ── row 3: HelmReleases ─────────────────────────────────────────────────────
run 3 healthy ok "" "{\"items\":[$(hr flux-system flux-instance True)]}" \
"[ok] HelmReleases all Ready"
run 3 not-ready ok "" "{\"items\":[$(hr flux-system flux-instance True),$(hr default app False)]}" \
"[fail] HelmReleases — Not Ready: default/app "
run 3 rbac-lost err "" "" \
"[warn] HelmReleases — could not run kubectl get hr -A -o json (rc=1: Error from server (Forbidden): hr is forbidden)$U"
run 3 not-json ok "" "Error from server" \
"[warn] HelmReleases — kubectl get hr -A -o json returned no item list$U"
run 3 empty-list ok "" '{"items":[]}' \
"[warn] HelmReleases — the HelmRelease list has no flux-system/flux-instance, which every cluster has, so it is not this cluster's list$U"

# ── row 4: abnormal pods + restarts ─────────────────────────────────────────
PODS_OK='kube-system   cilium-abc   1/1   Running   0   1d'
run 4 healthy ok "$PODS_OK" "{\"items\":[$(pod kube-system cilium-abc)]}" \
"[ok] Pods all healthy
[ok] No pods restarted in last 24h"
run 4 abnormal ok "$PODS_OK
default   app-x   0/1   CrashLoopBackOff   9   1d" "{\"items\":[$(pod kube-system cilium-abc)]}" \
"[fail] Pods abnormal — default/app-x (CrashLoopBackOff);
[ok] No pods restarted in last 24h"
run 4 rbac-lost err "" "" \
"[warn] Pods — could not run kubectl get pods -A --no-headers (rc=1: Error from server (Forbidden): pods is forbidden)$U
[warn] Pod restarts — could not run kubectl get pods -A -o json (rc=1: Error from server (Forbidden): pods is forbidden)$U"
run 4 empty ok "" '{"items":[]}' \
"[warn] Pods — the pod list has no pod in kube-system, which every cluster has, so it is not this cluster's list$U
[warn] Pod restarts — the pod list has no pod in kube-system, which every cluster has, so it is not this cluster's list$U"

# ── row 5: PVCs (an empty list is a real answer) ────────────────────────────
run 5 healthy ok "default   data   Bound   pv-1   1Gi   RWO   sc   1d" "" \
"[ok] PVCs all Bound"
run 5 pending ok "default   data   Pending                       sc   1d" "" \
"[fail] PVCs — default/data (Pending);"
run 5 none ok "" "" \
"[ok] PVCs all Bound"
run 5 rbac-lost err "" "" \
"[warn] PVCs — could not run kubectl get pvc -A --no-headers (rc=1: Error from server (Forbidden): pvc is forbidden)$U"

# ── row 8: TLS certificates ─────────────────────────────────────────────────
run 8 healthy ok "" "{\"items\":[{\"metadata\":{\"namespace\":\"network\",\"name\":\"wild\"},\"status\":{\"notAfter\":\"$NOW_PLUS_90D\"}}]}" \
"[ok] TLS certificates (>14d remaining)"
run 8 expiring ok "" "{\"items\":[{\"metadata\":{\"namespace\":\"network\",\"name\":\"wild\"},\"status\":{\"notAfter\":\"$NOW_PLUS_3D\"}}]}" \
"[warn] TLS certificates nearing expiry — network/wild expires $NOW_PLUS_3D;"
run 8 rbac-lost err "" "" \
"[warn] TLS certificates — could not run kubectl get certificate -A -o json (rc=1: Error from server (Forbidden): certificate is forbidden)$U"
run 8 not-json ok "" "nope" \
"[warn] TLS certificates — kubectl get certificate -A -o json returned no item list$U"

# ── row 9: Warning events (zero is a real answer) ───────────────────────────
run 9 none ok "" "" \
"[ok] Warning events in last hour: 0"
SPIKE="$(for i in $(seq 25); do echo "default   1m   Warning   BackOff   pod/x   msg"; done)"
run 9 spiked ok "$SPIKE" "" \
"[warn] Warning events spiked (25) — Top reasons:   25 BackOff;"
run 9 rbac-lost err "" "" \
"[warn] Warning events — could not run kubectl get events -A --field-selector type=Warning --no-headers (rc=1: Error from server (Forbidden): events is forbidden)$U"

# ── row 10: Cloudflare tunnel pods ──────────────────────────────────────────
run 10 healthy ok "network   cloudflare-tunnel-x   1/1   Running   0   1d" "" \
"[ok] Cloudflare tunnel pods Running"
run 10 crashing ok "network   cloudflare-tunnel-x   0/1   CrashLoopBackOff   5   1d" "" \
"[fail] Cloudflare tunnel pods — network/cloudflare-tunnel-x (CrashLoopBackOff);"
run 10 none ok "" "" \
"[warn] Cloudflare tunnel pods — no pod carries app.kubernetes.io/name=cloudflare-tunnel, and every cluster runs the tunnel$U"
run 10 rbac-lost err "" "" \
"[warn] Cloudflare tunnel pods — could not run kubectl get pod -A -l app.kubernetes.io/name=cloudflare-tunnel --no-headers (rc=1: Error from server (Forbidden): pod is forbidden)$U"

# ── row 13: node resource pressure ──────────────────────────────────────────
run 13 healthy ok "n1   500m   12%   2Gi   30%" "" \
"[ok] Node resource pressure normal"
run 13 pressure ok "n1   3500m   91%   2Gi   30%" "" \
"[warn] Node resource pressure — n1 CPU=91%% "
run 13 no-metrics err "" "" \
"[skip] Node resource pressure — the metrics API did not answer kubectl top nodes, so CPU and memory were not read"

# ── row 14: node disk pressure ──────────────────────────────────────────────
run 14 healthy ok "" "{\"items\":[$(node n1 False)]}" \
"[ok] Node disk pressure clear"
run 14 pressure ok "" "{\"items\":[$(node n1 True)]}" \
"[fail] Node DiskPressure — n1 "
run 14 empty-list ok "" '{"items":[]}' \
"[warn] Node disk pressure — the node list is empty$U"
run 14 rbac-lost err "" "" \
"[warn] Node disk pressure — could not run kubectl get nodes -o json (rc=1: Error from server (Forbidden): nodes is forbidden)$U"

# ── row 16: LoadBalancer addresses ──────────────────────────────────────────
run 16 healthy ok "" "{\"items\":[$(svc default kubernetes ClusterIP)]}" \
"[ok] LoadBalancer addresses assigned"
run 16 unsatisfied ok "" "{\"items\":[$(svc default kubernetes ClusterIP),$(svc network envoy LoadBalancer '{"type":"cilium.io/IPAMRequestSatisfied","status":"False","reason":"no_pool"}')]}" \
"[fail] LoadBalancer addresses — network/envoy=no_pool "
run 16 no-root ok "" "{\"items\":[$(svc network envoy LoadBalancer)]}" \
"[warn] LoadBalancer addresses — the Service list has no default/kubernetes, which every cluster has, so it is not this cluster's list$U"
run 16 rbac-lost err "" "" \
"[warn] LoadBalancer addresses — could not run kubectl get svc -A -o json (rc=1: Error from server (Forbidden): svc is forbidden)$U"

echo

# ── cross-case assertions ───────────────────────────────────────────────────
for key in "${!SEEN[@]}"; do
  case "$key" in
    */rbac-lost|*/not-json|*/empty-list|*/empty|*/no-root|*/no-metrics|10/none) ;;
    *) continue ;;
  esac
  if [[ "${SEEN[$key]}" == *"[ok]"* ]]; then
    echo "FAIL  row ${key%%/*} case ${key#*/} rendered ok. That is #217: a list that"
    echo "      could not be read printed the same ✅ as a healthy one."
    FAILED=$((FAILED + 1))
  fi
done
for row in 3 4 8 10 13 14 16; do
  if [[ "${SEEN[$row/healthy]}" != *"[ok]"* ]]; then
    echo "FAIL  row $row: the healthy case is not ok, so the cases above could be met"
    echo "      by a row that warns at everything."
    FAILED=$((FAILED + 1))
  fi
done
for key in 5/none 9/none; do
  if [[ "${SEEN[$key]}" != "[ok]"* ]]; then
    echo "FAIL  row ${key%%/*}: an empty answer is a real answer there (no PVC / no"
    echo "      Warning event) and must stay ok; the fix must not treat it as unmeasured."
    FAILED=$((FAILED + 1))
  fi
done

if (( FAILED > 0 )); then
  echo "FAILED: $FAILED case(s)"
  exit 1
fi
echo "ok — every case matches; no unreadable list renders ok on the nine rows"
