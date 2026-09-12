#!/usr/bin/env bash
# Assert this repo names factory's Omni credential by the role that is DEPLOYED.
#
# Found 2026-09-12 by FO-openspec [8e8ef1] while issuing the key: three places
# here said factory holds an Omni *Admin* service account, while
# app/credentials-secret.yaml had said "Operator, not Admin" since 2026-08-23,
# and Operator is what was issued. A credential inventory that overstates the
# role is not a harmless typo: the inventory is what a reader reaches for when
# deciding blast radius, and "Admin" invites someone to reissue at Admin
# because the docs said that was the shape.
#
# It does NOT forbid the string "Omni Admin". The correction note in README.md
# quotes the old wording, and a check for "the phrase is gone" fires on the
# correction that explains it — a false positive this repo has already paid for
# once. It flags only phrasings that CLAIM factory holds Admin, and it asserts
# the positive claims that must survive:
#
#   * the credential inventory row names Operator, not an Admin account;
#   * credentials-secret.yaml still carries the "Operator, not Admin" anchor;
#   * the open question survives: whether Operator suffices to CREATE a
#     cluster is not measured. That sentence is the reason the narrow role was
#     chosen, and deleting it would make the choice look settled.
#
# Usage: scripts/check-factory-omni-role.sh [repo-root]
#   exit 0 consistent, 1 a claim is wrong or a required statement is gone
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DIR="$ROOT/kubernetes/apps/extras/factory/factory"
FAILED=0

[[ -d "$DIR" ]] || { echo "CANNOT MEASURE: $DIR does not exist"; exit 1; }

# 1. Nothing may claim factory HOLDS an Omni Admin account.
CLAIMS=$(grep -rn -E '(concentrates|reach|holds|carries|an?) Omni Admin' "$DIR" || true)
if [[ -n "$CLAIMS" ]]; then
  echo "FAIL  something still claims factory holds an Omni ADMIN account:"
  echo "$CLAIMS" | sed "s#^$ROOT/#  #"
  echo "      What is deployed is Role Operator — see app/credentials-secret.yaml"
  echo "      and the factory_omni_sa_key row of fleet-ops handover-inventory.md."
  FAILED=$((FAILED + 1))
fi

# 2. The credential inventory row must name the deployed role.
ROW=$(grep -n '^| \*\*Omni' "$DIR/README.md" || true)
if [[ -z "$ROW" ]]; then
  echo "FAIL  CANNOT MEASURE: no Omni row found in the credentials table of README.md"
  FAILED=$((FAILED + 1))
elif grep -q 'Omni Admin' <<< "$ROW"; then
  # Checked separately from "does it say Operator": the row that named an Admin
  # account ALSO discussed Operator further along the same line, so asking only
  # for the word Operator passed on the wrong row. Caught by mutation.
  echo "FAIL  the credentials-table row still names an Omni ADMIN account: ${ROW:0:120}"
  FAILED=$((FAILED + 1))
elif ! grep -q 'Operator' <<< "$ROW"; then
  echo "FAIL  the credentials-table row does not name Role Operator: ${ROW:0:120}"
  FAILED=$((FAILED + 1))
fi

# 3. The anchor in credentials-secret.yaml. Without it, checks 1 and 2 are
#    asserting against nothing — that is "cannot measure", not a pass.
if ! grep -q 'Operator, not Admin' "$DIR/app/credentials-secret.yaml"; then
  echo "FAIL  CANNOT MEASURE: credentials-secret.yaml no longer says 'Operator, not Admin'."
  echo "      If the deployed role genuinely changed, change this guard deliberately;"
  echo "      if it did not, the one file that was right has lost the claim."
  FAILED=$((FAILED + 1))
fi

# 4. The open question must survive in both places that carry it.
for f in "$DIR/app/credentials-secret.yaml" "$DIR/README.md"; do
  if ! grep -q 'suffices to CREATE a cluster is NOT measured' "$f"; then
    echo "FAIL  ${f#$ROOT/} no longer says whether Operator suffices to CREATE a cluster is NOT measured"
    echo "      — deleting it makes a deliberately unmeasured choice read as settled."
    FAILED=$((FAILED + 1))
  fi
done

if (( FAILED )); then
  echo "$FAILED check(s) failed."
  exit 1
fi
echo "ok — the inventory names the deployed role (Operator), the anchor and the unmeasured question both survive"
