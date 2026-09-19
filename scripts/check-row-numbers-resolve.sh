#!/usr/bin/env bash
# Assert that every daily-check row number cited anywhere in this repo can be
# resolved to a row name by the one document that defines them.
#
# ferry133/jg-base#118: the report carries no numbers at all — `record()` emits
# `✅ ${name}` — so a number is repo dialect, resolvable only through the legend
# table in daily-check/README.md. That legend was missing 7 of the 26 numbered
# rows, 6 of them actively cited in prose and in operator-facing manifests, and
# the legend itself cited two numbers it did not define.
#
# The cost is already paid: FO-handler [f92b04] wrote "check 20 must appear" as
# an acceptance condition on ferry133/fleet-ops#12 and #13 — an identifier the
# person doing the accepting cannot see in the artefact they are accepting.
#
# ⚠️ NOT asserted here, deliberately:
#   * the legend's ROW ORDER. It is not numeric today and that is cosmetic.
#   * RENUMBERING. The numbers are referenced by CI, guards and manifests; the
#     risk of resequencing outweighs the tidiness (scope set on #118).
#   * whether a citation also spells out the row NAME. That is a judgement per
#     site (operator-facing yes, internal comment optional) and a guard that
#     demanded it everywhere would fire on correct code.
#
# Usage: scripts/check-row-numbers-resolve.sh
#   exit 0 every cited number resolves, 1 one did not, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "cannot measure: python3 is missing"; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "cannot measure: git is missing"; exit 2; }

# Set logic in python rather than `comm`: `comm` requires lexically sorted
# input and silently returns garbage on `sort -n`, with a well-formed list and
# exit 0 — it reads exactly like an answer. That happened while measuring this
# very defect (#118).
python3 - "$ROOT" <<'PY'
import os, re, subprocess, sys

root = sys.argv[1]
README = "kubernetes/apps/base/monitoring/daily-check/README.md"
SCRIPT = "kubernetes/apps/base/monitoring/daily-check/app/configmap.yaml"

def read(rel):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        print(f"cannot measure: {rel} not found"); sys.exit(2)
    return open(p, encoding="utf-8").read()

# A LIST first, then the set: the set is what resolves citations, but two
# table rows claiming the same number collapse into one member and the count
# does not move. A count is not a detector (FO-handler [f92b04], mutation M2 on
# #120). Same reason `legend` is compared to `coded` in BOTH directions below.
legend_rows = [int(m) for m in re.findall(r'^\| (\d+) \|', read(README), re.M)]
legend = set(legend_rows)
coded  = {int(m) for m in re.findall(r'^    # (\d+)[a-z]?\. ', read(SCRIPT), re.M)}

CITE = re.compile(r'\b(?:checks?|rows?)\s+(\d+)(?:\s+and\s+(\d+))?\b')

def cited_in(text):
    out = set()
    for m in CITE.finditer(text):
        out.add(int(m.group(1)))
        if m.group(2):
            out.add(int(m.group(2)))
    return out

files = subprocess.run(["git", "-C", root, "ls-files"],
                       capture_output=True, text=True).stdout.split()
sites = {}
for rel in files:
    p = os.path.join(root, rel)
    try:
        text = open(p, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    for n in cited_in(text):
        sites.setdefault(n, []).append(rel)

rc = 0
def fail(msg):
    global rc
    print(f"FAIL — {msg}"); rc = 1

# --- the measuring apparatus must be able to speak before its silence counts.
if len(legend) < 20:
    print(f"cannot measure: the legend parsed to only {len(legend)} rows, which is not a legend"); sys.exit(2)
if not coded:
    print("cannot measure: no numbered rows were found in the script"); sys.exit(2)
if not sites:
    print("cannot measure: the citation scan found nothing at all, so 'no violations' would be meaningless"); sys.exit(2)

# --- 1. every number that exists in the script must be in the legend.
missing = sorted(coded - legend)
if missing:
    fail("numbered rows exist in the script but not in the legend: "
         + ", ".join(str(n) for n in missing)
         + f" — a reader holding {README} cannot resolve them")

# --- 1b. and every number in the legend must exist in the script. Without
#     this the legend can grow a row no check implements, and the PASS line
#     would print "27 rows" next to "26 numbered rows" with nothing comparing
#     them — two numbers side by side is not a comparison (M1 on #120).
phantom = sorted(legend - coded)
if phantom:
    fail("the legend defines rows that no check implements: "
         + ", ".join(str(n) for n in phantom)
         + " — a reader would look for them in a report that can never print them")

# --- 1c. and it must define each number once. Two rows claiming the same
#     number both look authoritative, and which one a reader obeys depends on
#     which they read first; the deduplicating set hides it and the row count
#     does not move (M2 on #120). "Two copies inevitably diverge, and the one
#     being followed is usually the wrong one" — fleet-ops/CLAUDE.md, here in
#     its within-one-file form.
dupes = sorted({n for n in legend_rows if legend_rows.count(n) > 1})
if dupes:
    fail("the legend defines these numbers more than once: "
         + ", ".join(f"{n}×{legend_rows.count(n)}" for n in dupes)
         + " — the duplicates disagree eventually, and nothing says which row is meant")

# --- 2. every number cited anywhere must be in the legend.
unresolvable = sorted(set(sites) - legend)
for n in unresolvable:
    where = ", ".join(sorted(set(sites[n]))[:4])
    fail(f"the number {n} is cited but the legend does not define it (cited in: {where})")

# --- 3. positive control: a number that IS defined must not be reported.
#     Without this, "legend == everything" would satisfy 1 and 2 vacuously.
probe = max(legend)
if probe in unresolvable or probe in missing:
    print(f"cannot measure: control failed — {probe} is in the legend yet was reported"); sys.exit(2)

# --- 4. negative control: a synthetic citation of an undefined number must be
#     caught by the same function that scans the repo. Built in memory, never
#     written into the tree, so this file cannot pollute its own scan.
synthetic = 99 if 99 not in legend else max(legend) + 77
probe_text = f"See daily-check's check {synthetic} for the rest."
found = cited_in(probe_text)
if synthetic not in found:
    fail("negative control is broken: the scanner did not see a synthetic citation, "
         "so a real unresolvable citation would also be invisible")
elif synthetic in legend:
    fail("negative control is broken: the synthetic number is defined in the legend")

if rc == 0:
    # States the comparison, not the two operands. Printing "27 rows" beside
    # "26 numbered rows" and leaving the reader to notice is how M1 passed.
    print(f"PASS — legend and script define the SAME {len(legend)} rows "
          f"(both differences empty, {len(legend_rows)} table rows, no number twice); "
          f"{len(sites)} distinct numbers cited across the repo, all resolvable")
    print("       (negative control: a synthetic citation of an undefined number is seen by the same scanner)")
sys.exit(rc)
PY
