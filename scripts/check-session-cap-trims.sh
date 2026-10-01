#!/usr/bin/env bash
# Assert the claudecode archive's session cap keeps the NEWEST transcripts and
# never touches memory/ -- by running the real loop, not a copy of it.
#
# ferry133/jg-base#145 condition 5. The cap ("keep the newest SESSION_KEEP
# transcripts per project") is the one piece of archive.sh that can be wrong
# in a way nothing downstream notices: a cap that matches nothing still
# produces an archive, uploads it, and logs a size. "Skipped 0" and "there was
# nothing to skip" are the same line. A cap that kept the OLDEST would also
# produce an archive of exactly the expected shape and the right member count.
#
# So the subject here is behaviour, and it is measured by EXECUTING the block
# out of the ConfigMap against a synthetic tree. The block is extracted, never
# re-typed: a guard holding its own copy of the loop keeps passing after the
# shipped loop changes, which is the failure this is built to avoid. The only
# thing the script needed for that was `STATE_ROOT` (a variable whose sole
# consumer is this guard; the Job never sets it).
#
# ⚠️ What this does NOT settle, and it is the thing most likely to be wrong:
# whether a real claude-config PVC is laid out as `projects/<slug>/<uuid>.jsonl`
# at all. The synthetic tree is built TO that assumption, so it cannot test it
# -- an instrument built from a premise cannot check the premise. If the real
# layout differs, every assertion below still passes and the live cap matches
# nothing. That is condition 8's job, and it is why the live run has to print
# the skipped transcripts BY NAME rather than only the archive size.
#
# Usage: scripts/check-session-cap-trims.sh
#   exit 0 the cap behaves, 1 it does not, 2 cannot measure
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM="$ROOT/kubernetes/apps/base/claudecode/claude-code/im/enabled/state-archive-script.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: $CM not readable"; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

yq -r '.data["archive.sh"]' "$CM" >"$WORK/archive.sh" 2>/dev/null
[[ -s "$WORK/archive.sh" ]] || { echo "cannot measure: could not read data['archive.sh'] out of $CM"; exit 2; }

# --- extract the block, anchored on the section markers in the script -------
sed -n '/^# --- session history cap/,/^# --- the members/p' "$WORK/archive.sh" \
  | sed '$d' >"$WORK/block.sh"
# Extraction has to be checked before anything is read off it: an empty or
# truncated block runs clean and skips nothing, which reads as a pass.
for token in 'SESSION_KEEP' 'ls -1t' '--exclude=' 'SESSION_EXCLUDES'; do
  grep -qF -- "$token" "$WORK/block.sh" \
    || { echo "cannot measure: the extracted block has no '$token' in it — the markers in archive.sh moved, so this guard is reading the wrong lines"; exit 2; }
done

# --- the synthetic tree -----------------------------------------------------
# alpha exceeds the cap (25 > 20), beta is under it, memory/ is full of files
# with the same extension and must never be considered.
T="$WORK/state"
mkdir -p "$T/config/projects/alpha" "$T/config/projects/beta" "$T/config/memory"
mk() { # mk <dir> <count>  -- s01 oldest .. sNN newest
  local d="$1" n="$2" i
  for ((i = 1; i <= n; i++)); do
    : >"$d/$(printf 's%02d.jsonl' "$i")"
    touch -t "$(printf '2026010101%02d' "$i")" "$d/$(printf 's%02d.jsonl' "$i")"
  done
}
mk "$T/config/projects/alpha" 25
mk "$T/config/projects/beta" 3
mk "$T/config/memory" 30

run() { # run <block> [env assignments...] -> prints "SKIPPED=n" then "EX <path>" lines
  local blk="$1"; shift
  { echo 'log() { :; }'
    echo "STATE_ROOT=$(printf '%q' "$T")"
    cat "$blk"
    echo 'echo "SKIPPED=${SKIPPED}"'
    echo 'for e in ${SESSION_EXCLUDES[@]+"${SESSION_EXCLUDES[@]}"}; do echo "EX ${e#--exclude=}"; done'
  } >"$WORK/run.sh"
  env -u CLAUDECODE_SESSION_KEEP "$@" bash "$WORK/run.sh"
}

OUT="$WORK/out"
run "$WORK/block.sh" >"$OUT" 2>"$WORK/err" || {
  echo "cannot measure: the extracted block exited non-zero against the synthetic tree"; sed -n '1,5p' "$WORK/err"; exit 2; }

skipped() { sed -n 's/^SKIPPED=//p' "$1"; }
excl()    { sed -n 's/^EX //p' "$1" | sort; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# --- A1: it trims, and it trims the right number ---------------------------
n="$(skipped "$OUT")"
[[ "$n" == "5" ]] \
  || fail "25 transcripts in one project with SESSION_KEEP=20 should skip 5; the block skipped '${n}' — a cap that matches nothing logs 'skipping 0' and still uploads a complete-looking archive"

# --- A2: the five it dropped are the five OLDEST ---------------------------
# This is the assertion that separates a cap from a coin flip: keeping the
# oldest drops exactly as many files, names them in the same format, and
# produces an archive of the same shape.
want="$(printf 'projects/alpha/s%02d.jsonl\n' 1 2 3 4 5 | sort)"
got="$(excl "$OUT")"
[[ "$got" == "$want" ]] \
  || fail "the skipped set is not the 5 oldest alpha transcripts — got: $(tr '\n' ' ' <<<"$got")"

# --- A3: memory/ is never considered ---------------------------------------
# Vacuity gate first: with zero exclusions this assertion passes while
# measuring nothing, so it is only allowed to speak when A1 found some.
if [[ "$n" == "0" ]]; then
  fail "no exclusions were produced at all, so 'memory/ was untouched' would be true of a cap that does nothing"
elif grep -q '^memory/' <<<"$got"; then
  fail "the cap excluded something under memory/ — transcripts are replayable detail, memory is the distilled result, and trimming the second to save space throws away the part worth keeping"
fi

# --- A4: the knob is live --------------------------------------------------
OUT2="$WORK/out2"
if run "$WORK/block.sh" CLAUDECODE_SESSION_KEEP=2 >"$OUT2" 2>/dev/null; then
  n2="$(skipped "$OUT2")"
  [[ "$n2" == "24" ]] \
    || fail "SESSION_KEEP=2 should skip 23 of alpha and 1 of beta = 24; got '${n2}' — a cap wired to a constant reads identically to a configurable one at the default"
else
  echo "note: could not run the block with CLAUDECODE_SESSION_KEEP=2, so the knob is unverified"
fi

# --- controls: can these assertions fail at all? ---------------------------
# Each mutation is gated on actually having changed the text, then the
# assertion it targets must FIRE. A control that cannot fire certifies nothing.
ctl_rc=0
ctl() { echo "cannot measure: $1"; ctl_rc=2; }

# C1 — reverse the sort: the cap now keeps the oldest. A2 must notice.
sed 's/ls -1t /ls -1tr /' "$WORK/block.sh" >"$WORK/m1.sh"
if cmp -s "$WORK/block.sh" "$WORK/m1.sh"; then
  ctl "the newest-vs-oldest control did not change the block (the 'ls -1t' call moved), so A2 is unverified"
elif run "$WORK/m1.sh" >"$WORK/c1" 2>/dev/null && [[ "$(excl "$WORK/c1")" == "$want" ]]; then
  ctl "keeping the OLDEST transcripts produced the same skipped set as keeping the newest — A2 cannot tell the two apart and its pass above means nothing"
fi

# C2 — scan every dir under config/, memory/ included. A3 must fire.
sed 's|/config/projects|/config|g' "$WORK/block.sh" >"$WORK/m2.sh"
if cmp -s "$WORK/block.sh" "$WORK/m2.sh"; then
  ctl "the memory/ control did not change the block, so A3 is unverified"
elif run "$WORK/m2.sh" >"$WORK/c2" 2>/dev/null && ! excl "$WORK/c2" | grep -q '^memory/'; then
  ctl "pointing the loop straight at memory/ still produced no memory/ exclusion — A3 is a check that cannot fire, and one of those reads exactly like a check that passed"
fi

# C3 — control-flow mutation: delete the line that records an exclusion.
grep -v 'SESSION_EXCLUDES+=' "$WORK/block.sh" >"$WORK/m3.sh"
if cmp -s "$WORK/block.sh" "$WORK/m3.sh"; then
  ctl "the control-flow control did not change the block, so A2's dependence on the recorded exclusions is unverified"
elif run "$WORK/m3.sh" >"$WORK/c3" 2>/dev/null && [[ "$(excl "$WORK/c3")" == "$want" ]]; then
  ctl "deleting the line that records exclusions left the skipped set unchanged — A2 is reading something other than this block"
fi

# A failed control means the readings above are unreliable, but it must not
# erase a real assertion failure: a defect found is worth more than a doubt.
if [[ $rc -ne 0 ]]; then
  [[ $ctl_rc -ne 0 ]] && echo "note: a control also failed; the FAIL above stands either way"
  exit 1
fi
[[ $ctl_rc -ne 0 ]] && exit 2

echo "PASS — the shipped session-cap block, run against a synthetic tree: skipped 5 of alpha's 25 and they were the 5 oldest, left beta's 3 and memory/'s 30 alone, and tracked SESSION_KEEP=2 to 24"
echo "       (controls: keeping the oldest, scanning memory/, and deleting the recording line each break an assertion above)"
echo "       ⚠️ the on-disk layout itself is assumed, not tested — condition 8's live run must print skipped transcripts by name"
exit 0
