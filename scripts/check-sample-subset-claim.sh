#!/usr/bin/env bash
# `cluster-secrets.sample.yaml` must keep saying what it is: an example, not an
# inventory.
#
# Found 2026-09-12 by FO-handler [f92b04], via one missing line
# (FACTORY_OMNI_SA_KEY_EXPIRES). Measuring it showed the gap was not one line:
# most declared names were absent, whole families at a time — every FACTORY_*,
# BACKUP_R2_* and DAILY_CHECK_* key. Adding the one line would have left a
# subset that still reads like an inventory — README.md said it documented
# "all required keys" — and absence would still have read as "not needed".
#
# No counts are written in this comment either. The first version of this file
# said "20 of 80" here while asserting the same numbers below, which is the
# pinning the fix deliberately avoids in the files it guards (f92b04, again).
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

SAMPLE_KEYS=$(grep -oE '^  [A-Z][A-Z0-9_]*:' "$SAMPLE" | tr -d ' :' | sort -u)
SAMPLE_N=$(grep -c . <<< "$SAMPLE_KEYS" || true)
VOCAB_N=$(grep -vcE '^\s*(#|$)' "$VOCAB")

# Keys the sample carries that this repo never substitutes. They are real:
# cluster-secrets is consumed by jg-cluster-template's templates too, and a key
# only those render appears in no substitution under kubernetes/. Measured 2026-09-12 —
# each is in jgct's cluster-secrets.sops.yaml.j2 and in no jg-base manifest.
#
# An allowlist rather than silence, because the same "in the sample, nowhere
# else" shape is also what a typo looks like: f92b04 added FO_HANDLER_FAKE_KEY
# and the first version of this guard stayed green, since it only ever compared
# in one direction.
declare -A SAMPLE_ONLY_OK=(
  [CLUSTER_API_ADDR]="rendered by jg-cluster-template and declared in its cluster.schema.cue; no jg-base manifest substitutes it"
  [NAS_CODING_PATH]="rendered by jg-cluster-template; declared in its cluster.schema.cue"
)
UNKNOWN=()
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  grep -qxF "$k" "$VOCAB" && continue
  [[ -n "${SAMPLE_ONLY_OK[$k]:-}" ]] && continue
  UNKNOWN+=("$k")
done <<< "$SAMPLE_KEYS"
DECLARED_HERE=$(( SAMPLE_N - ${#SAMPLE_ONLY_OK[@]} - ${#UNKNOWN[@]} ))

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
#    and this guard, deliberately. Compared on the intersection, not on the raw
#    key count — two of the sample's keys are not declared here at all.
if (( DECLARED_HERE >= VOCAB_N )); then
  echo "FAIL  the sample covers ${DECLARED_HERE} of ${VOCAB_N} declared names —"
  echo "      it is no longer the subset it calls itself."
  FAILED=$((FAILED + 1))
fi

# 2b. A key here that this repo never substitutes, and that is not one of the
#     known jgct-rendered ones, is either a typo or a key nothing reads. Both
#     mislead exactly the reader this file is for.
if (( ${#UNKNOWN[@]} > 0 )); then
  echo "FAIL  the sample carries ${#UNKNOWN[@]} key(s) that no substitution under kubernetes/ uses"
  echo "      and that are not known jg-cluster-template keys:"
  for k in "${UNKNOWN[@]}"; do echo "        ${k}"; done
  echo "      Add it to substitution-vocabulary.txt if a manifest reads it, list"
  echo "      it in SAMPLE_ONLY_OK here with the reason if jgct renders it, or"
  echo "      remove it: an example key nothing reads is worse than a missing one."
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
echo "ok — the sample carries ${SAMPLE_N} keys: ${DECLARED_HERE} of the ${VOCAB_N} declared here, plus ${#SAMPLE_ONLY_OK[@]} that jg-cluster-template renders. It says it is an example, and the families it calls absent are absent"
