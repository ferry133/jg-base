#!/usr/bin/env bash
# Run Flux's OWN substitution engine over every manifest Flux will substitute,
# and assert it parses.
#
# ferry133/jg-base#123, 2026-09-20: two explanatory comments in
# claudecode/postgres/app/migration.yaml contained a single-dollar braced
# ellipsis while explaining that you must write the doubled form. envsubst
# scans the whole rendered text, comments included, and `${...}` is not a
# variable name — so it refused the entire Job with "unable to parse variable
# name" and the claudecode-db Kustomization went `Ready=False BuildFailed` on
# ALL THREE clusters. The comment warning about the form was written in the
# form it warned about.
#
# ⚠️ Why the real binary and not a pattern. The guard that shipped that change
# already simulated Flux — it rewrote `$$` to `$` with sed so it could run the
# script. The simulation was faithful for the code and blind to the comments,
# because the guard stripped comments before looking and the engine does not.
# Nothing made of regexes would have caught this; the engine would have, on the
# first run. So: no approximation here, only `flux envsubst`.
#
# ⚠️ Scope, and why it is not "every YAML in the repo". Eight files in this
# repo do not parse and seven of them are CORRECT: three carry
# `kustomize.toolkit.fluxcd.io/substitute: disabled` (Flux never substitutes
# them, which is the whole point of the annotation), and the others are not
# under a substituting path. A guard that failed on those would be flagging
# working manifests, and a guard that fires on correct code is the one that
# gets switched off. The predicate is therefore: a file must parse IF AND ONLY
# IF Flux will actually substitute it.
#
# Usage: scripts/check-envsubst-parses.sh
#   exit 0 everything Flux substitutes parses, 1 something does not, 2 cannot
#          measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "cannot measure: cannot enter $ROOT"; exit 2; }
command -v flux >/dev/null 2>&1 || { echo "cannot measure: the flux CLI is missing — this check refuses to approximate it (see the header)"; exit 2; }
command -v yq   >/dev/null 2>&1 || { echo "cannot measure: yq is missing"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
rc=0
fail() { echo "FAIL — $1"; rc=1; }

# --- the instrument must be able to say both words before its silence counts.
printf 'a: "${A_VALID_NAME}"\n' > "$WORK/good.yaml"
printf 'a: "b"\n# ${...}\n'      > "$WORK/bad.yaml"
flux envsubst < "$WORK/good.yaml" >/dev/null 2>&1 \
  || { echo "cannot measure: flux envsubst rejected a plainly valid variable name, so a rejection below would say nothing"; exit 2; }
flux envsubst < "$WORK/bad.yaml"  >/dev/null 2>&1 \
  && { echo "cannot measure: flux envsubst ACCEPTED an unparseable braced sequence, so this whole check cannot discriminate"; exit 2; }

# --- which paths does Flux substitute? Ask the Kustomizations in this repo.
SUBST_PATHS="$WORK/paths"; : > "$SUBST_PATHS"
while IFS= read -r ks; do
  yq -r 'select(.kind == "Kustomization") | select(.spec.postBuild.substituteFrom != null) | .spec.path // ""' "$ks" 2>/dev/null \
    | grep -v '^$' >> "$SUBST_PATHS"
done < <(grep -rl 'kind: Kustomization' kubernetes --include='*.yaml' 2>/dev/null)
sort -u -o "$SUBST_PATHS" "$SUBST_PATHS"
[[ -s "$SUBST_PATHS" ]] || { echo "cannot measure: found no Kustomization with postBuild.substituteFrom, so 'nothing failed' would be meaningless"; exit 2; }

scanned=0; exempt=0; unresolved=0
while IFS= read -r p; do
  d="${p#./}"
  # A path can itself be templated (extras/default/postgres/backup/<var>).
  # Say so rather than skip silently: an unscanned file and a passing file must
  # not read the same.
  case "$d" in *'${'*) unresolved=$((unresolved + 1)); echo "note: path is templated, not scanned: $d"; continue ;; esac
  [[ -d "$d" ]] || { unresolved=$((unresolved + 1)); echo "note: path does not exist in this repo, not scanned: $d"; continue ; }
  while IFS= read -r f; do
    if grep -q 'kustomize\.toolkit\.fluxcd\.io/substitute: disabled' "$f"; then
      exempt=$((exempt + 1)); continue
    fi
    scanned=$((scanned + 1))
    if ! err="$(flux envsubst < "$f" 2>&1 >/dev/null)"; then
      fail "flux envsubst cannot parse $f: ${err//$'\n'/ } — Flux will refuse the whole object and the Kustomization goes Ready=False BuildFailed. A braced sequence that is not a variable name does this even inside a comment."
    fi
  done < <(find "$d" -name '*.yaml' -type f | sort)
done < "$SUBST_PATHS"

[[ "$scanned" -gt 0 ]] || { echo "cannot measure: resolved $(wc -l < "$SUBST_PATHS" | tr -d ' ') substituting path(s) but scanned no files"; exit 2; }

if [[ $rc -eq 0 ]]; then
  echo "PASS — ${scanned} manifest(s) under $(wc -l < "$SUBST_PATHS" | tr -d ' ') substituting path(s) parse with the real flux envsubst"
  echo "       (${exempt} skipped as substitute: disabled, ${unresolved} path(s) unresolved and named above;"
  echo "        instrument controls: a valid name is accepted and an unparseable one is rejected)"
fi
exit $rc
