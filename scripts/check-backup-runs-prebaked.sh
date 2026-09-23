#!/usr/bin/env bash
# Assert that offsite-backup runs a pinned pre-baked image, installs nothing at
# run time, and calls no command that was not declared when that image was
# chosen.
#
# ferry133/jg-base#124: the container used to `apk add` its whole toolchain on
# every schedule. On the slow appliance that took **over 11 minutes** against a
# backup body of seconds (13m27s total, 2026-09-20). Image layers are cached by
# containerd; `apk add` is not, so the old form paid the whole download again
# every night.
#
# ⚠️ What this guard CANNOT do, stated rather than skipped: it cannot look
# inside the image. CI has no registry client and no runtime. So the half it
# checks is "backup.sh asks for nothing beyond what was declared"; the half it
# cannot check is "the image still provides them". Those are different
# premises, and only one of them lives in this repo. The likelier break is the
# first — a script grows a call — which is why it is worth guarding even alone.
#
# The other half was measured ONCE, by hand, and is recorded here so the next
# person does not have to guess: FO-openspec [8e8ef1] went into ops-b8fe918 on
# 2026-09-23 and found bash, age, aws, kubectl, tar, gzip, sha256sum, jq, curl,
# getent and nslookup present, and pg_dump, psql, mc, yq and envsubst absent
# from the whole filesystem. The absences are CORRECT: the dumps run via
# `kubectl exec` inside the database pod. ⚠️ That is a reading with a date on
# it, not a standing guarantee — the image can be rebuilt.
#
# ⚠️ DECLARED is derived from what backup.sh CALLS, never from the old `apk
# add` line. That line installed postgresql16-client, which the script never
# invokes; a list copied from it would make this guard demand five commands
# nobody needs — firing on a correct image, which is how a guard gets switched
# off.
#
# ⚠️ And the method has a hole, found the same day: `gzip` is in the list yet
# appears NOWHERE at command position. backup.sh:366 is `tar -czf`, and the
# compression is a dependency of that flag. An indirect dependency — reached
# through a flag, a library, or another binary — is invisible to "extract the
# command-position tokens". So the list is command-position calls PLUS anything
# known to be pulled in sideways, and the second part is human. If you add an
# entry, say which kind it is.
#
# Usage: scripts/check-backup-runs-prebaked.sh
#   exit 0 all three hold, 1 one did not, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CJ="$ROOT/kubernetes/apps/base/monitoring/backup/app/cronjob.yaml"
CM="$ROOT/kubernetes/apps/base/monitoring/backup/app/configmap.yaml"
for f in "$CJ" "$CM"; do [[ -r "$f" ]] || { echo "cannot measure: $f not readable"; exit 2; }; done
command -v yq      >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "cannot measure: python3 is missing"; exit 2; }

# Declared when ops-b8fe918 was chosen (ferry133/k8scc#11, 1a re-confirmed
# 2026-09-22 against that digest). `age`, `aws` and `kubectl` are the three the
# image adds; the rest come from the base and coreutils. `gzip` is the odd
# one out: it is never called directly — it is what `tar -czf` at
# backup.sh:366 needs (see the header). ⚠️ Adding a name here
# is a claim that the IMAGE has it — check ops-toolchain.json before you do,
# because this file cannot.
DECLARED="age aws kubectl awk sed grep tar gzip tr wc tail cat ls mkdir mktemp rm date"

rc=0
fail() { echo "FAIL — $1"; rc=1; }

IMAGE="$(yq -r 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].image' "$CJ")"
CMD="$(yq -r 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].command | join(" ")' "$CJ")"
[[ -n "$IMAGE" && "$IMAGE" != "null" ]] || { echo "cannot measure: could not read the backup container's image from $CJ"; exit 2; }

# --- 1. pinned by digest, not by a moving tag.
case "$IMAGE" in
  *@sha256:*) : ;;
  *) fail "the backup image '${IMAGE}' is not pinned by digest — ops-latest was measured pointing at the WRONG image for ~20 minutes on 2026-09-22 when three builds raced it, and a skewed moving tag reads exactly like a correct one (k8scc#11)" ;;
esac

# --- 2. nothing is installed at run time. This is the defect itself.
case "$CMD" in
  *apk\ add*|*apt-get*|*apt\ install*|*pip\ install*|*npm\ install*)
    fail "the backup container installs packages at run time again (command: ${CMD}) — that is #124, and on the slow appliance it cost 11 of the Job's 13 minutes" ;;
esac
# and the script it runs must not do it either
grep -qE '(^|[;&|`]|\$\()[[:space:]]*(apk[[:space:]]+add|apt-get|pip[[:space:]]+install)' <(yq -r '.data["backup.sh"]' "$CM") \
  && fail "backup.sh installs packages at run time — the pre-baked image is bypassed from inside"

# --- 3. the script calls nothing that was not declared.
# ⚠️ The python below exits 2 for "cannot measure" and 1 for a real finding.
# Collapsing both into 1 would put a broken instrument and a real regression in
# the same colour -- the mistake this repo made in #113 and keeps re-learning.
set +e
python3 - "$CM" "$DECLARED" <<'PY'
import sys, io, re, subprocess
cm, declared = sys.argv[1], set(sys.argv[2].split())
body = subprocess.run(["yq", "-r", '.data["backup.sh"]', cm],
                      capture_output=True, text=True).stdout
if not body.strip():
    print("cannot measure: backup.sh could not be read out of the ConfigMap"); sys.exit(2)
lines = [l.split(' #')[0] for l in body.split('\n') if not l.strip().startswith('#')]
src = '\n'.join(lines)

# ⚠️ Blank out QUOTED LITERALS before looking for commands, while keeping the
# contents of `$( )` -- those are code. The first draft skipped this and
# reported `keeping` and `refusing` as undeclared commands: both live inside
# `log "..."` messages, and one of them sits after a `;` INSIDE the string
# ("no usable retention cutoff; keeping every archive"), which reads to a
# command-position regex exactly like the start of a new command.
def blank_literals(t):
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c == '$' and t[i:i+2] == '$(':          # keep substitutions: code
            depth, j = 1, i + 2
            while j < n and depth:
                if t[j] == '(': depth += 1
                elif t[j] == ')': depth -= 1
                j += 1
            out.append('$(' + blank_literals(t[i+2:j-1]) + ')'); i = j; continue
        if c in "'\"":
            j = i + 1
            while j < n and t[j] != c:
                if c == '"' and t[j:j+2] == '$(':   # a substitution inside "..."
                    depth, k = 1, j + 2
                    while k < n and depth:
                        if t[k] == '(': depth += 1
                        elif t[k] == ')': depth -= 1
                        k += 1
                    out.append('$(' + blank_literals(t[j+2:k-1]) + ')'); j = k; continue
                j += 1
            out.append(' '); i = j + 1; continue
        out.append(c); i += 1
    return ''.join(out)

src_raw = src
src = blank_literals(src)
BUILTIN = set("""if then else elif fi for while until do done case esac function return exit
local export set unset shift read echo printf eval exec trap source . [ [[ test true false
cd pwd break continue declare let time in select getopts wait kill command builtin type""".split())
funcs = set(re.findall(r'^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{', src, re.M))
vars_ = set(re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=', src, re.M))
def extract(t):
    seen = set()
    for m in re.finditer(r'(?:^|[;&|]|\(|\{|\bif\b|\bthen\b|\bdo\b|\bwhile\b|\buntil\b|\$\()\s*([a-z][a-z0-9_.+-]*)\b', t, re.M):
        seen.add(m.group(1))
    ext = {c for c in seen if c not in BUILTIN and c not in funcs and c not in vars_ and len(c) > 1}
    out = set()
    for c in sorted(ext):
        if re.search(r'(?:^|[;&|`]|\$\()\s*' + re.escape(c) + r'(?:\s+[-"\'$/\w]|\s*[|<>]|\s*$)', t, re.M):
            out.add(c)
    return out
# a word only counts as a command if it is followed by an argument, a pipe, a
# redirect or end-of-line at least once -- prose inside a string otherwise
# leaks in, which it did on the first draft of this check.
real = extract(src)
# ⚠️ Control on the BLANKER, because the thing that fails silently here is an
# extractor that sees fewer commands: fewer calls than declared is never an
# error, so a broken instrument and a clean script produce the same green.
#
# A first attempt used `date` as a sentinel ("it only appears inside `$( )`").
# Measured: with blanking removed entirely, `date` is still found -- so that
# sentinel could never fire, which is the one thing a control must never be.
# This asks the blanker to do its job instead: run the same extractor on the
# RAW text and require that blanking actually removed something. It does, and
# what it removes is known -- `keeping` and `refusing`, both words sitting
# inside `log "..."` messages, one of them after a `;` INSIDE the string.
raw_real = extract(src_raw)
if not (raw_real - real):
    print("cannot measure: blanking quoted literals changed nothing, so it is not running "
          "-- every name below may be prose from inside a string")
    sys.exit(2)

undeclared = sorted(real - declared)
if undeclared:
    print("FAIL — backup.sh calls " + ", ".join(undeclared) +
          ", which was not declared when the image was pinned. Either the image has it "
          "(check ops-toolchain.json, then add it to DECLARED) or it does not and the "
          "backup dies at run time with nothing in this repo having said so.")
    sys.exit(1)
print(f"  (declared {len(declared)}, script calls {len(real)}, undeclared 0)")
PY

PYRC=$?
set -e
set +e
case "$PYRC" in
  0) : ;;
  2) exit 2 ;;
  *) rc=1 ;;
esac

if [[ $rc -eq 0 ]]; then
  echo "PASS — backup runs ${IMAGE%%@*} pinned by digest, installs nothing at run time,"
  echo "       and calls only declared commands. NOT checked: that the image still"
  echo "       provides them (no registry client in CI) — see the header."
fi
exit $rc
