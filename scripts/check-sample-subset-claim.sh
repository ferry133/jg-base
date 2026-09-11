#!/usr/bin/env bash
# `cluster-secrets.sample.yaml` must keep saying what it is: an example, not an
# inventory.
#
# Found 2026-09-12 by FO-handler [f92b04], via one missing line
# (FACTORY_OMNI_SA_KEY_EXPIRES). Measuring it showed the gap was not one line:
# the file carried 20 of the 80 declared names, with every FACTORY_*,
# BACKUP_R2_* and DAILY_CHECK_* key absent. Adding the one line would have left
# a subset that still reads like an inventory — README.md said it documented
# "all required keys" — and absence would still have read as "not needed".
#
# Hand-copying the rest is refused on FO-openspec [8e8ef1]'s criterion: do not
# hand-copy what is generated. The two complete lists are generated or enforced
# (substitution-vocabulary.txt, and jg-cluster-template's
# cluster-secrets.sops.yaml.j2), and a third hand-kept copy would drift.
#
# This asserts the RELATION rather than a number. The first version of this
# guard pinned "20 of 80" and asserted both counts — and an open PR adding one
# variable would have broken main's CI and forced a hand edit in another
# branch. A number in a file is invalidated by other people's work; the
# relation is not. The counts are printed on every run, where they are current.
#
# Usage: scripts/check-sample-subset-claim.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE="$ROOT/kubernetes/components/sops/cluster-secrets.sample.yaml"
VOCAB="$ROOT/scripts/substitution-vocabulary.txt"
README="$ROOT/README.md"
FAILED=0

SAMPLE_N=$(grep -cE '^  [A-Z][A-Z0-9_]*:' "$SAMPLE")
VOCAB_N=$(grep -vcE '^\s*(#|$)' "$VOCAB")

# Anti-vacuous: if either count is zero the comparison below would "pass" while
# measuring nothing.
if (( SAMPLE_N == 0 || VOCAB_N == 0 )); then
  echo "FAIL  CANNOT MEASURE: sample keys=${SAMPLE_N}, vocabulary names=${VOCAB_N}."
  echo "      One of the two files stopped parsing the way this guard reads it."
  exit 1
fi

# 1. Both files must still say it is not an inventory. Deleting the sentence is
#    how this file silently becomes one again.
for f in "$SAMPLE" "$README"; do
  if ! grep -qi 'not an inventory' "$f"; then
    echo "FAIL  ${f#$ROOT/} no longer says the sample is not an inventory."
    echo "      Without it, a reader takes absence for 'not needed' — the defect this fixes."
    FAILED=$((FAILED + 1))
  fi
done

# 2. The claim must remain true: a strict subset, not a full list wearing a
#    warning. If someone completes it, the honest move is to delete the warning
#    and this guard, deliberately.
if (( SAMPLE_N >= VOCAB_N )); then
  echo "FAIL  the sample carries ${SAMPLE_N} keys against ${VOCAB_N} declared names —"
  echo "      it is no longer the subset it calls itself."
  FAILED=$((FAILED + 1))
fi

# 3. The families the sample NAMES as absent must actually be absent. The
#    families are read out of the file's own comment, so the check follows the
#    claim instead of a list typed here: edit the sentence and the guard
#    follows; add a FACTORY_* key without touching the sentence and it fails.
#    (FO-openspec [8e8ef1] asked for exactly this property in a different
#    form: the sentence must not be able to go quietly false.)
FAMS=$(grep -oE '\b[A-Z][A-Z0-9_]*_\*' "$SAMPLE" | tr -d '*' | sort -u)
FAM_N=$(grep -c . <<< "$FAMS" || true)
if (( FAM_N < 2 )); then
  echo "FAIL  CANNOT MEASURE: the sample names ${FAM_N} absent families; the warning"
  echo "      lists three. Either the sentence was reworded past recognition or the"
  echo "      pattern here stopped matching it."
  FAILED=$((FAILED + 1))
else
  while IFS= read -r fam; do
    [[ -n "$fam" ]] || continue
    # Anti-vacuous: a family nobody declares would be "absent" for free.
    if ! grep -qE "^${fam}" "$VOCAB"; then
      echo "FAIL  the sample says ${fam}* keys are absent, but no ${fam}* name is declared"
      echo "      at all — that claim measures nothing."
      FAILED=$((FAILED + 1))
      continue
    fi
    PRESENT=$(grep -cE "^  ${fam}" "$SAMPLE" || true)
    if (( PRESENT > 0 )); then
      echo "FAIL  the sample says every ${fam}* key is absent, and ${PRESENT} of them is present."
      echo "      Adding one is fine — but then the sentence has to change with it."
      FAILED=$((FAILED + 1))
    fi
  done <<< "$FAMS"
fi

# 4. README must not go back to promising completeness — and the check has to
#    survive the correction that QUOTES the old promise. Matching the promise
#    text alone fires on "it used to be described here as documenting all
#    required keys"; matching only the original wording misses a reworded one
#    (measured: a lower-case rewrite walked straight past the first version of
#    this check). So: any line claiming completeness must also mark itself as
#    history.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if ! grep -qiE 'used to|no longer|until|stopped' <<< "$line"; then
    echo "FAIL  README.md promises the sample documents all required keys:"
    echo "        ${line}"
    echo "      If this is describing the old promise, say so on the same line"
    echo "      ('used to', 'no longer'); if it is a new promise, it is false."
    FAILED=$((FAILED + 1))
  fi
done <<< "$(grep -iE '(all|every) required[^.]{0,40}(key|variable)' "$README" || true)"

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — the sample carries ${SAMPLE_N} of ${VOCAB_N} declared names, says so, and the families it calls absent are absent"
