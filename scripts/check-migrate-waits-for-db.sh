#!/usr/bin/env bash
# Assert that the postgres migration Job waits for the database instead of
# racing it, and that the wait is bounded and says why when it gives up.
#
# ferry133/jg-base#123: on a cold cluster the Job started while postgres was
# still waiting for its PVC, spent the default backoffLimit of 6 on `psql:
# connection refused`, and went Failed 73 seconds before postgres came Ready.
# Measured on a rebuilt appliance 2026-09-20: created 15:57:14, Failed
# 16:03:16, postgres Running 16:04:29. ttlSecondsAfterFinished then GC'd the
# Failed Job and the next Kustomization interval rebuilt it at 16:56:37, where
# it succeeded in four seconds.
#
# So the path self-heals — and that is exactly why it needs a guard rather than
# a bug report. **The database has no schema for one Flux interval** (53
# minutes on that cluster) while `im` is free to connect to it, and every
# outside signal during that window looks like a cluster that is coming up
# normally.
#
# ⚠️ NOT asserted here: the 900-second bound and the 5-second poll. They are
# judgement, not contract — a cluster slower than the one measured may want
# more. What is asserted is that a bound EXISTS and that exceeding it fails
# loudly, because an unbounded wait turns a failed migration into a Job that
# never finishes and never complains.
#
# Usage: scripts/check-migrate-waits-for-db.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MF="$ROOT/kubernetes/apps/base/claudecode/postgres/app/migration.yaml"
[[ -r "$MF" ]] || { echo "cannot measure: $MF not readable"; exit 2; }
# yq, not a hand-rolled parser: initContainers sits four levels deep, and this
# repo's recurring injury is a pattern that looks right until the shape moves.
# CI installs yq pinned by version AND digest for scripts/check-lan-dns-row.sh,
# so this adds no dependency (ferry133/jg-base#32).
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it; locally see .github/workflows/flux-local.yaml)"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

JOBSPEC='select(.kind == "Job") | .spec.template.spec'
N_JOBS="$(yq -r 'select(.kind == "Job") | .metadata.name' "$MF" | grep -c . || true)"
[[ "$N_JOBS" == "1" ]] || { echo "cannot measure: expected exactly one Job in $MF, found ${N_JOBS}"; exit 2; }

N_INIT="$(yq -r "$JOBSPEC | (.initContainers // []) | length" "$MF")"

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# --- 1. the Job must have an initContainer at all. This is the regression.
if [[ "${N_INIT:-0}" -lt 1 ]]; then
  fail "the migration Job has no initContainer — it races postgres again, and on a cold cluster it loses (#123)"
  exit $rc
fi

WAIT="$WORK/wait.sh"
# ⚠️ The text in the manifest is NOT the text the cluster runs. This Job is
# applied by the `claudecode-db` Kustomization with postBuild substituteFrom,
# so Flux rewrites `$${X}` to a literal `${X}` before the container starts.
# Running the raw text would exercise something that never runs: `$${PGHOST}`
# in a shell is the PID followed by `{PGHOST}`, which is how this guard first
# reported a message that "does not name the host" — the message was fine, the
# harness was testing the wrong string. Undo the escape here, which is exactly
# what Flux does, and nothing else.
#
# The other half — that the escape is PRESENT, so an unescaped `${PGHOST}` is
# not silently emptied by substitution on the cluster — belongs to
# scripts/check-substitution-vocabulary.sh and is already enforced there. Not
# duplicated: two guards sharing one premise are one guard, but these two have
# different premises and each catches its own direction.
yq -r "$JOBSPEC | .initContainers[0].command[-1]" "$MF" | sed 's/[$][$]{/${/g' > "$WAIT"
yq -r "$JOBSPEC | [.initContainers[0].image, .containers[0].image] | .[]" "$MF" > "$WORK/images"
sh -n "$WAIT" || { echo "cannot measure: the extracted init script does not parse"; exit 2; }
# Comments stripped first: the script's own comment explains why pg_isready
# needs no password, so grepping the raw text would be satisfied by prose after
# the call itself was removed. An assertion a comment can satisfy is not an
# assertion about the code.
grep -v '^[[:space:]]*#' "$WAIT" | grep -q 'pg_isready' \
  || fail "no line of the init script CALLS pg_isready (a comment mentioning it does not count) — whatever it waits for, it is not 'postgres accepts connections'"

# --- 2. same image as the migrate container. On the node that produced #123 a
#     second image pull costs minutes; a fix that waits faster but pulls more
#     loses on the cluster it was written for.
a="$(sed -n 1p "$WORK/images")"; b="$(sed -n 2p "$WORK/images")"
[[ "$a" == "$b" ]] \
  || fail "the initContainer image ($a) differs from the migrate image ($b) — that is a second pull on a node where pulls are the problem"

# Run the real script against a stubbed pg_isready. Each case its own subshell.
probe() {
  local tries="$1" budget="$2"
  ( export PGHOST=db.example PATH="$WORK/bin:$PATH"
    printf '%s' "$tries" > "$WORK/tries"
    timeout "$budget" sh "$WAIT" 2>&1
    echo "rc=$?" )
}
mkdir -p "$WORK/bin"
cat > "$WORK/bin/pg_isready" <<'STUB'
#!/bin/sh
n=$(cat "$WORK_TRIES" 2>/dev/null || echo 0)
[ "$n" -le 0 ] && exit 0
echo $((n - 1)) > "$WORK_TRIES"
exit 1
STUB
chmod +x "$WORK/bin/pg_isready"
export WORK_TRIES="$WORK/tries"

# --- 3. already up: succeeds immediately.
out="$(probe 0 20)"
grep -q 'rc=0' <<<"$out" || fail "with postgres already accepting connections the wait did not succeed: $(tr '\n' '|' <<<"$out")"

# --- 4. up after a few polls: still succeeds. Without this, "exit 0 always"
#     would satisfy case 3.
out="$(probe 2 40)"
grep -q 'rc=0' <<<"$out" || fail "postgres accepting on the third poll did not succeed: $(tr '\n' '|' <<<"$out")"
grep -q 'waiting for' <<<"$out" || fail "the wait printed nothing while waiting — a silent wait and a hung pod look the same in the log"

# --- 5. the bound exists and failing says why. Rebuilt with a tiny deadline so
#     the case runs in seconds; the real number is judgement, its existence is
#     not.
sed 's/+ 900 ))/+ 2 ))/; s/within 900s/within 2s/; s/sleep 5/sleep 1/' "$WAIT" > "$WORK/short.sh"
cmp -s "$WAIT" "$WORK/short.sh" && { echo "cannot measure: could not shorten the deadline, so the bound was not exercised"; exit 2; }
out="$( export PGHOST=db.example PATH="$WORK/bin:$PATH"; printf '9999' > "$WORK/tries"
        timeout 30 sh "$WORK/short.sh" 2>&1; echo "rc=$?" )"
# rc=124 is the harness killing it, not the script giving up. Distinguish the
# two: "it never returned" and "it returned an error" are different defects and
# a message that names the wrong one sends the next reader to the wrong line.
if grep -q 'rc=124' <<<"$out"; then
  fail "the wait was still running when the harness stopped it — its own deadline never fired, so the bound is missing or far larger than the script says"
elif grep -q 'rc=0' <<<"$out"; then
  fail "a database that never came up still exited 0 — the migration would be skipped silently"
fi
grep -q 'db.example' <<<"$out" \
  || fail "the give-up message does not name the host it waited for: $(tr '\n' '|' <<<"$out")"
grep -qi 'no schema' <<<"$out" \
  || fail "the give-up message does not say what the consequence is; 'timed out' alone reads like a transient"

if [[ $rc -eq 0 ]]; then
  echo "PASS — the Job waits on pg_isready with the migrate image, succeeds when postgres is up"
  echo "       or comes up, speaks while waiting, and on a bounded timeout fails naming the host"
  echo "       and the consequence (the 900s bound and 5s poll are judgement, not asserted)"
fi
exit $rc
