#!/usr/bin/env bash
# jg-base main does not move under kubernetes/apps/extras any more
# (jg-base#211; split-extras 5.1; fleet-ops root `split-extras-repo` D5 as
# decided by ferry133 2026-10-22, option A).
#
# Extras live in ferry133/jg-extras now. jg-jiahd switched to it at jg-jiahd
# 239e774 (2026-10-24, 4.2); jcom keeps reading the frozen copy here until
# its own switch (4.3). Before this guard, four commits landed here after the
# split and reached nothing: jg-jiahd ran an old linebot for ~13h
# (jg-extras#7, fixed by the re-sync jg-extras#8). So this check is red on any
# change under kubernetes/apps/extras/** relative to FREEZE, pinned below.
# Change extras in jg-extras instead.
#
# Escape hatch -- an urgent fix that jcom needs before 4.3 (omni, factory):
#   1. land the change in jg-extras first, in its own PR;
#   2. in the jg-base PR, make the same change AND move FREEZE to that PR's
#      head commit, naming the jg-extras PR next to the pin;
#   3. that jg-base PR needs ferry133's nod before merging (a moved pin is
#      the only diff to this file, so it cannot pass unnoticed).
# Moving FREEZE without step 1 re-opens jg-extras#7: the two copies diverge
# and jg-jiahd does not get the fix.
#
# Usage: .github/scripts/check-extras-frozen.sh [--self-test]
#   exit 0 unchanged, 1 changed, 2 cannot measure
#   Needs history back to FREEZE (actions/checkout fetch-depth: 0).
set -uo pipefail
SYNC=1fe49e3696ce06f1f4a3626f5f2907ce00b97221  # FREEZE: what jg-extras a1360dc (jg-extras#8) re-synced to
SUB=kubernetes/apps/extras
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "cannot measure: no repo root"; exit 2; }
git cat-file -e "$SYNC^{commit}" 2>/dev/null \
  || { echo "cannot measure: freeze commit ${SYNC:0:7} is not in this clone (shallow? use fetch-depth: 0)"; exit 2; }
git cat-file -e "$SYNC:$SUB" 2>/dev/null || { echo "cannot measure: $SUB missing at ${SYNC:0:7}"; exit 2; }

check() {  # REF -> FAIL lines or ok; 0/1/2
  local ref="$1" changed
  git cat-file -e "$ref:$SUB" 2>/dev/null || { echo "cannot measure: $SUB missing at $ref"; return 2; }
  changed="$(git diff --no-renames --name-status "$SYNC" "$ref" -- "$SUB")" || { echo "cannot measure: git diff failed"; return 2; }
  if [[ -z "$changed" ]]; then
    echo "ok — $SUB at $(git rev-parse --short "$ref") is unchanged since the freeze ${SYNC:0:7}"
    return 0
  fi
  while IFS=$'\t' read -r st f; do
    echo "FAIL — $f changed here since the freeze ${SYNC:0:7} ($st). Extras change in jg-extras now; see the escape hatch at the top of this file"
  done <<<"$changed"
  return 1
}

if [[ "${1:-}" != "--self-test" ]]; then check HEAD; exit $?; fi

# Self-test: fixture commits built in a private index, never checked out and
# never referenced by a branch.
W="$(mktemp -d "${TMPDIR:-/tmp}/jgb-frozen.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$W"' EXIT
F="$SUB/default/mqtt/app/kustomization.yaml"
git cat-file -e "HEAD:$F" 2>/dev/null || { echo "cannot measure: fixture file $F missing"; exit 2; }
fixture() {  # MUTATION -> commit sha on stdout
  local blob
  GIT_INDEX_FILE="$W/index" git read-tree HEAD || return 2
  case "$1" in
    edit)    blob="$( { git cat-file -p "HEAD:$F"; printf '# drift\n'; } | git hash-object -w --stdin)" || return 2
             GIT_INDEX_FILE="$W/index" git update-index --cacheinfo "100644,$blob,$F" ;;
    add)     blob="$(printf 'x: 1\n' | git hash-object -w --stdin)" || return 2
             GIT_INDEX_FILE="$W/index" git update-index --add --cacheinfo "100644,$blob,$SUB/default/mqtt/app/extra.yaml" ;;
    delete)  GIT_INDEX_FILE="$W/index" git update-index --force-remove "$F" ;;
    outside) blob="$(printf 'outside extras\n' | git hash-object -w --stdin)" || return 2
             GIT_INDEX_FILE="$W/index" git update-index --add --cacheinfo "100644,$blob,docs-fixture.md" ;;
  esac || return 2
  # A fixed identity: CI runners have none, and commit-tree refuses without one.
  GIT_AUTHOR_NAME=self-test GIT_AUTHOR_EMAIL=self-test@invalid \
  GIT_COMMITTER_NAME=self-test GIT_COMMITTER_EMAIL=self-test@invalid \
    git commit-tree "$(GIT_INDEX_FILE="$W/index" git write-tree)" -p HEAD -m "frozen self-test: $1" </dev/null
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
expect "1 one extras file edited" 1 "$F changed here" edit
expect "2 an extras file added"   1 "extra.yaml changed here" add
expect "3 an extras file deleted" 1 "$F changed here since the freeze ${SYNC:0:7} (D)" delete
expect "4 a change outside extras stays green" 0 "unchanged since the freeze" outside
[[ $gauge -eq 0 ]] || { echo "cannot measure: the self-test could not build its fixtures"; exit 2; }
[[ $rc -eq 0 ]] && echo "ok — self-test: HEAD passes, three kinds of extras change each fail, a change outside extras does not"
exit $rc
