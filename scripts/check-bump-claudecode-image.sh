#!/usr/bin/env bash
# Assert scripts/bump-claudecode-image.sh rewrites the claude-code pins and
# nothing else -- by running the real script against the real HelmRelease.
#
# ferry133/jg-base#269. The script's pattern took every digest-shaped `tag:`
# line. That was right while claude-code was the only image pinned that way in
# im/enabled/helmrelease.yaml, and became wrong the day #220 pinned
# oauth2-proxy in the same file. The script's own site count stopped it, so no
# wrong pin shipped, but every k8scc image bump failed from then on and
# nothing in this repo's CI ran the script to say so.
#
# Two fixtures, because the first one depends on what the file holds today:
#   real      the HelmRelease as it is on this commit
#   foreign   the same file plus one appended image block from another
#             repository with a digest-shaped tag. This one keeps the guard
#             discriminating if the file ever stops pinning a second image.
# The registry lookup is the only thing replaced: a `gh` stub that answers the
# one query the script makes and fails on any other.
#
# What this does NOT measure: the lookup against GHCR, and the k8scc workflow
# that calls the script.
#
# Usage: scripts/check-bump-claudecode-image.sh [--self-test]
#   exit 0 only claude-code pins change, 1 something else does, 2 cannot measure
#   BUMP_SCRIPT=<path> runs another copy of the script (the self-test uses it)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/check-bump-claudecode-image.sh"
SCRIPT="${BUMP_SCRIPT:-$ROOT/scripts/bump-claudecode-image.sh}"
REL="kubernetes/apps/base/claudecode/claude-code/im/enabled/helmrelease.yaml"
HR="$ROOT/$REL"
REPO="ghcr.io/ferry133/claude-code"
NEWSHA="1234abc"
DIGEST="sha256:$(printf 'ab%.0s' $(seq 32))"
PIN="${NEWSHA}@${DIGEST}"

[[ -r "$SCRIPT" ]] || { echo "cannot measure: $SCRIPT not readable"; exit 2; }
[[ -r "$HR" ]] || { echo "cannot measure: $HR not readable"; exit 2; }
for tool in perl diff awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "cannot measure: $tool is missing"; exit 2; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bumpcheck.XXXXXX")" || { echo "cannot measure: no temp directory"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

if [[ "${1:-}" == "--self-test" ]]; then
  fails=0
  cell() { # name, expected rc, script-under-test
    BUMP_SCRIPT="$3" bash "$SELF" >"$WORK/out" 2>&1; local rc=$?
    if [[ "$rc" -eq "$2" ]]; then echo "ok   $1 (rc=$rc)"
    else echo "FAIL $1: expected rc=$2, got rc=$rc"; sed 's/^/     /' "$WORK/out"; fails=$((fails+1)); fi
  }
  mutate() { # name, sed expression  -> $WORK/<name>.sh, gated on the file changing
    sed "$2" "$SCRIPT" >"$WORK/$1.sh"
    if cmp -s "$SCRIPT" "$WORK/$1.sh"; then echo "cannot measure: mutation $1 did not change the script"; exit 2; fi
    bash -n "$WORK/$1.sh" || { echo "cannot measure: mutation $1 does not parse"; exit 2; }
  }
  cell "0 unmutated script" 0 "$SCRIPT"
  # m1: the #269 defect itself -- every digest-shaped tag is rewritten.
  mutate m1 's/ if \$r eq \$ENV{REPO}//'
  cell "m1 rewrite ignores the repository" 1 "$WORK/m1.sh"
  # m2: the same defect with the script's own site count loosened, so only
  # this guard's line-by-line comparison is left to catch it.
  mutate m2 's/ if \$r eq \$ENV{REPO}//; s/"\$n" -ne 3/"$n" -lt 3/'
  cell "m2 same, and the script's count no longer stops it" 1 "$WORK/m2.sh"
  # m3: the script aims at another repository.
  mutate m3 's|^REPO=.*|REPO="quay.io/oauth2-proxy/oauth2-proxy"|'
  cell "m3 rewrite aims at another repository" 1 "$WORK/m3.sh"
  # m4: the rewrite line is gone.
  mutate m4 '/perl -pi -e/d'
  cell "m4 rewrite line deleted" 1 "$WORK/m4.sh"
  cell "cm script under test missing" 2 "$WORK/absent.sh"
  [[ "$fails" -eq 0 ]] || { echo "self-test FAILED: $fails cell(s)"; exit 1; }
  echo "self-test ok: 6 cells"; exit 0
fi

# --- gh stub: answers the one query the script makes, fails on any other ----
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"packages/container/claude-code/versions"*"$NEWSHA"*) echo "$DIGEST" ;;
  *) echo "stub gh: unexpected call: \$*" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

fail=0
run_fixture() { # name, source helmrelease
  local name="$1" src="$2" t="$WORK/$1"
  mkdir -p "$t/scripts" "$t/$(dirname "$REL")"
  cp "$SCRIPT" "$t/scripts/bump-claudecode-image.sh" && cp "$src" "$t/$REL" \
    || { echo "cannot measure: could not build fixture $name"; exit 2; }
  local out rc
  out="$(PATH="$WORK/bin:$PATH" bash "$t/scripts/bump-claudecode-image.sh" "$NEWSHA" 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL [$name] the script returned $rc:"; sed 's/^/     /' <<<"$out"; fail=1; return
  fi
  # Each line, with the repository its tag belongs to (nearest one above).
  local verdict
  verdict="$(awk -v repo="$REPO" -v pin="$PIN" '
    NR == FNR { before[FNR] = $0; next }
    { old = before[FNR]; new = $0 }
    old ~ /^[[:space:]]*repository:/ { r = old; sub(/^[[:space:]]*repository:[[:space:]]*/, "", r) }
    old ~ /^[[:space:]]*tag:.*@sha256:/ {
      if (r == repo) { want++; if (new ~ ("tag: " pin "$")) got++ ; else printf "line %d: a claude-code tag was not rewritten\n", FNR }
      else { other++; if (old != new) printf "line %d: a tag under %s was changed\n", FNR, r }
      next
    }
    old != new { printf "line %d: a line that is not a pinned tag was changed\n", FNR }
    END { printf "counts %d %d %d\n", want, got, other }' "$src" "$t/$REL")"
  [[ "$(wc -l <"$src")" -eq "$(wc -l <"$t/$REL")" ]] || { echo "FAIL [$name] the line count changed"; fail=1; }
  local counts; counts="$(grep '^counts ' <<<"$verdict")"
  local problems; problems="$(grep -v '^counts ' <<<"$verdict" || true)"
  local want got other; read -r _ want got other <<<"$counts"
  if [[ -n "$problems" ]]; then echo "FAIL [$name]"; sed 's/^/     /' <<<"$problems"; fail=1; fi
  if [[ "$want" -ne 3 || "$got" -ne 3 ]]; then
    echo "FAIL [$name] expected 3 claude-code tags, all rewritten; saw $want, rewritten $got"; fail=1
  fi
  if [[ "$name" == foreign && "$other" -lt 1 ]]; then
    echo "cannot measure: the foreign fixture holds no tag under another repository"; exit 2
  fi
  echo "     [$name] claude-code tags rewritten: $got of $want; tags under other repositories, compared byte for byte: $other"
}

run_fixture real "$HR"
cp "$HR" "$WORK/foreign.yaml"
cat >>"$WORK/foreign.yaml" <<'YAML'
          guard-fixture:
            image:
              repository: registry.example/not-claude-code
              tag: v1.2.3@sha256:0000000000000000000000000000000000000000000000000000000000000000
YAML
run_fixture foreign "$WORK/foreign.yaml"

[[ "$fail" -eq 0 ]] || exit 1
echo "ok — in both fixtures the bump changed the claude-code tags and no other line"
