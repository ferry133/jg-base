#!/usr/bin/env bash
# Assert every backup CronJob this repo ships carries the declared subject.
#
# ferry133/jg-base#85: daily-check's backup row used to find backups by name
# alone. A name is a convention, not a contract -- a CronJob called
# `pg-dump-nightly` was a real backup and invisible to that row, and nothing
# would have said so: it would simply not appear, and the count line would show
# a smaller, entirely reasonable-looking number.
#
# The row's subject is now a union: `app.kubernetes.io/component: backup`, OR a
# `*-backup` name. The name half exists for CronJobs a controller generates for
# us -- Longhorn's `daily-backup`, which cannot be labelled from here because
# RecurringJob.spec.labels labels the snapshots, not the CronJob it creates.
#
# This guard covers the half that IS ours: anything this repo ships whose name
# ends in `-backup` must also declare the label. Without it the union quietly
# degrades to name-matching-only, and **a union that is only working on one
# side renders exactly like one working on both**.
#
# Derived from the tree, not from a list: a fixture of paths written here would
# omit precisely the backup nobody remembered to add to it. That is not
# hypothetical -- `freepbx/freepbx-file-backup` was found by enumeration on
# 2026-09-09 by someone who did not know it existed.
#
# Usage: scripts/check-backup-label.sh   (exit 0 if every one carries it)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="app.kubernetes.io/component"
WANT="backup"

command -v yq >/dev/null || {
  echo "yq required. CI installs it pinned in the 'scripts' job of"
  echo ".github/workflows/flux-local.yaml."
  exit 1
}

FOUND=0
MISSING=()
LABELLED=()

while IFS= read -r f; do
  # One line per CronJob document in the file: "<name>|<label value or ->"
  while IFS='|' read -r name lbl; do
    [[ -z "${name:-}" ]] && continue
    FOUND=$((FOUND + 1))
    if [[ "$name" == *-backup ]]; then
      if [[ "$lbl" == "$WANT" ]]; then
        LABELLED+=("$name")
      else
        MISSING+=("${f#"$ROOT"/} :: $name (${lbl})")
      fi
    elif [[ "$lbl" == "$WANT" ]]; then
      # Not a *-backup name but declares the label. That is the case #85 exists
      # for and it is correct -- name it so the coverage line is readable.
      LABELLED+=("$name")
    fi
  done < <(yq -r 'select(.kind == "CronJob")
                  | .metadata.name + "|" + (.metadata.labels["'"$LABEL"'"] // "-")' "$f" 2>/dev/null || true)
done < <(grep -rl --include='*.yaml' '^kind: CronJob' "$ROOT/kubernetes" 2>/dev/null || true)

# Anti-vacuous. A parser that stopped matching finds nothing and passes every
# per-item check below -- which is the failure this repo keeps paying for.
if (( FOUND == 0 )); then
  echo "FAIL  no CronJob documents were found under kubernetes/ at all."
  echo "      Either the tree moved or this script stopped parsing. An empty"
  echo "      inventory passes every check below and proves nothing."
  exit 1
fi

echo "found ${FOUND} CronJob(s) under kubernetes/"
if ((${#LABELLED[@]})); then
  printf 'ok    labelled: %s\n' "$(printf '%s ' "${LABELLED[@]}")"
fi

if ((${#MISSING[@]})); then
  echo
  for m in "${MISSING[@]}"; do echo "FAIL  $m"; done
  echo
  echo "Each of these is a backup this repo ships whose name says so but which"
  echo "does not declare ${LABEL}: ${WANT}. daily-check's backup row still finds"
  echo "them today -- by name. Rename one and it vanishes from the report with"
  echo "nothing going red, which is #85."
  exit 1
fi

echo "ok — every *-backup CronJob shipped from this repo declares ${LABEL}: ${WANT}"
