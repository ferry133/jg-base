#!/usr/bin/env bash
# kubernetes/apps/extras does not exist in jg-base (split-extras 5.3).
#
# Extras live in ferry133/jg-extras. History: jg-base was the single writer
# until the cutover (fleet-ops root `split-extras-repo` D5, ferry133 option A,
# 2026-10-22); four commits that landed here after the split reached nothing
# and jg-jiahd ran an old linebot for ~13h (jg-extras#7). 5.1 froze the copy
# here at 1fe49e3 (#211/#213); once both production readers (jg-jiahd, jcom)
# read jg-extras, 5.3 deleted it. This check is red if anything is tracked
# under kubernetes/apps/extras again -- a second copy diverges silently, and
# no cluster reads this one. Change extras in jg-extras.
#
# Usage: .github/scripts/check-extras-frozen.sh [--self-test]
#   exit 0 absent, 1 present, 2 cannot measure
set -uo pipefail
SUB=kubernetes/apps/extras
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "cannot measure: no repo root"; exit 2; }

check() {  # REF -> FAIL lines or ok; 0/1/2
  local ref="$1" present
  git cat-file -e "$ref^{tree}" 2>/dev/null || { echo "cannot measure: $ref is not a commit here"; return 2; }
  # The sanity anchor is a path this check does not test: kubernetes/ must exist.
  git cat-file -e "$ref:kubernetes" 2>/dev/null || { echo "cannot measure: kubernetes/ missing at $ref"; return 2; }
  present="$(git ls-tree -r --name-only "$ref" -- "$SUB")" || { echo "cannot measure: git ls-tree failed"; return 2; }
  if [[ -z "$present" ]]; then
    echo "ok — $SUB is absent at $(git rev-parse --short "$ref"); extras live in ferry133/jg-extras"
    return 0
  fi
  while IFS= read -r f; do
    echo "FAIL — $f is tracked here. Extras live in ferry133/jg-extras since split-extras 5.3; no cluster reads this copy"
  done <<<"$present"
  return 1
}

if [[ "${1:-}" != "--self-test" ]]; then check HEAD; exit $?; fi

# Self-test: fixture commits built in a private index, never checked out and
# never referenced by a branch.
W="$(mktemp -d "${TMPDIR:-/tmp}/jgb-extras-absent.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$W"' EXIT
fixture() {  # MUTATION -> commit sha on stdout
  local blob
  GIT_INDEX_FILE="$W/index" git read-tree HEAD || return 2
  case "$1" in
    add)     blob="$(printf 'x: 1\n' | git hash-object -w --stdin)" || return 2
             GIT_INDEX_FILE="$W/index" git update-index --add --cacheinfo "100644,$blob,$SUB/default/mqtt/ks.yaml" ;;
    dotfile) blob="$(printf '\n' | git hash-object -w --stdin)" || return 2
             GIT_INDEX_FILE="$W/index" git update-index --add --cacheinfo "100644,$blob,$SUB/.keep" ;;
    outside) blob="$(printf 'outside extras\n' | git hash-object -w --stdin)" || return 2
             GIT_INDEX_FILE="$W/index" git update-index --add --cacheinfo "100644,$blob,docs-fixture.md" ;;
  esac || return 2
  # A fixed identity: CI runners have none, and commit-tree refuses without one.
  GIT_AUTHOR_NAME=self-test GIT_AUTHOR_EMAIL=self-test@invalid \
  GIT_COMMITTER_NAME=self-test GIT_COMMITTER_EMAIL=self-test@invalid \
    git commit-tree "$(GIT_INDEX_FILE="$W/index" git write-tree)" -p HEAD -m "extras-absent self-test: $1" </dev/null
}
rc=0 gauge=0
expect() {  # NAME WANT_RC WANT_TEXT MUTATION
  local c out mrc
  # A fixture that cannot be built is a broken gauge, not a caught change: exit 2.
  c="$(fixture "$4")" || { echo "CANNOT MEASURE  $1: could not build the fixture"; gauge=2; return; }
  [[ "$(git rev-parse "$c^{tree}")" != "$(git rev-parse "HEAD^{tree}")" ]] || { echo "CANNOT MEASURE  $1: fixture equals HEAD, the mutation did not apply"; gauge=2; return; }
  out="$(check "$c")"; mrc=$?
  if [[ $mrc -eq $2 ]] && grep -qF -- "$3" <<<"$out"; then echo "PASS  $1  ->  $(grep -F -- "$3" <<<"$out" | head -1)"
  else echo "FAIL  $1: rc=$mrc wanted $2 and \"$3\": $out"; rc=1; fi
}
out="$(check HEAD)"; mrc=$?
if [[ $mrc -eq 0 ]]; then echo "PASS  0 HEAD as is  ->  $out"; else echo "FAIL  0 HEAD as is: rc=$mrc $out"; rc=1; fi
expect "1 an extras manifest comes back"   1 "$SUB/default/mqtt/ks.yaml is tracked here" add
expect "2 even a dotfile under extras"     1 "$SUB/.keep is tracked here" dotfile
expect "3 a change outside extras stays green" 0 "is absent at" outside
[[ $gauge -eq 0 ]] || { echo "cannot measure: the self-test could not build its fixtures"; exit 2; }
[[ $rc -eq 0 ]] && echo "ok — self-test: HEAD passes, anything tracked under extras fails, a change outside does not"
exit $rc
