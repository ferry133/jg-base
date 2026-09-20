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
# Everything below works on LABELS (`17`, `17a`), never on bare integers.
#
# ⚠️ This is the correction that cost the most on #120. The script pattern used
# to demand EXACTLY four leading spaces. `# 17a.` at configmap.yaml:723 is
# indented six, so the guard never saw it — and the sentence "there are no
# lettered sub-rows today" was itself produced by that same pattern. **An
# instrument certified the absence of the thing it is blind to.** 17a is a real
# row: it prints on every report, it is cited in four places, and the legend
# had no entry for it, which is #118's own sentence living inside #118's guard.
#
# So: any indent. Verified rather than assumed — the relaxed pattern matches 27
# lines in configmap.yaml and all 27 are real row headers (FO-handler [f92b04]
# and jgb-handler [20db54] each listed them, independently, with the indent
# printed alongside so a mismatch could not hide in the count).
legend_rows = re.findall(r'^\| (\d+[a-z]?) \|', read(README), re.M)
legend = set(legend_rows)
coded_labels = re.findall(r'^[ \t]*# (\d+[a-z]?)\. ', read(SCRIPT), re.M)
coded = set(coded_labels)

def order(label):
    m = re.match(r'(\d+)([a-z]?)', label)
    return (int(m.group(1)), m.group(2))

# The suffix is part of the identity: without it `check 17a` resolves to `17`,
# which IS in the legend, so a citation of an undocumented sub-row reads as
# resolvable. That is how 17a stayed invisible through three rounds.
CITE = re.compile(r'\b(?:checks?|rows?)\s+(\d+[a-z]?)(?:\s+and\s+(\d+[a-z]?))?\b')

def cited_in(text):
    out = set()
    for m in CITE.finditer(text):
        out.add(m.group(1))
        if m.group(2):
            out.add(m.group(2))
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
missing = sorted(coded - legend, key=order)
if missing:
    fail("numbered rows exist in the script but not in the legend: "
         + ", ".join(str(n) for n in missing)
         + f" — a reader holding {README} cannot resolve them")

# --- 1b. and every number in the legend must exist in the script. Without
#     this the legend can grow a row no check implements, and the PASS line
#     would print "27 rows" next to "26 numbered rows" with nothing comparing
#     them — two numbers side by side is not a comparison (M1 on #120).
phantom = sorted(legend - coded, key=order)
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
dupes = sorted({n for n in legend_rows if legend_rows.count(n) > 1}, key=order)
if dupes:
    fail("the legend defines these numbers more than once: "
         + ", ".join(f"{n}×{legend_rows.count(n)}" for n in dupes)
         + " — the duplicates disagree eventually, and nothing says which row is meant")

# --- 1d. the SCRIPT must define each row once too. Symmetric with 1c: the set
#     above absorbs a repeat on this side just as readily (M3 on #120).
script_dupes = sorted({l for l in coded_labels if coded_labels.count(l) > 1}, key=order)
if script_dupes:
    fail("the script defines these rows more than once: "
         + ", ".join(f"{l}×{coded_labels.count(l)}" for l in script_dupes)
         + " — two sections claiming one number, and the legend can only describe one of them")

# --- 1e. anything that LOOKS like a row header but is not in the accepted
#     shape must be flagged. This is the inversion #121 asked for: 1a-1d
#     enumerate what is allowed, and an enumeration is blind to whatever it
#     does not list. `# 17a.` sat six spaces deep for months while the pattern
#     demanded four; the guard read `all resolvable` every day, and the
#     sentence "there are no lettered sub-rows" was produced by that same
#     pattern. An instrument certified the absence of what it cannot see.
#
#     So: cast a WIDE net for "this comment declares something numbered", then
#     subtract the accepted shape. What is left is either a new row in a shape
#     nobody agreed to, or prose that happens to look like one — and the second
#     kind must be named, one exemption at a time, with its reason.
WIDE   = re.compile(r'^([ \t]*)#[ \t]*(\S*\d\S*[.])[ \t]', re.M)
STRICT = re.compile(r'^[ \t]*# \d+[a-z]?\. ')

# Each exemption is a SHAPE with a reason, never a line number: line numbers
# drift and an exemption that drifts starts covering something else. Keep this
# list short. ⚠️ A long exemption list and no guard at all are the same thing —
# case 1f below empties it on purpose to prove the list is still load-bearing.
EXEMPT = [
    # `# 6403b5c. Measured in that image: ...` — a commit SHA quoted in prose.
    # Seven-plus hex characters is not a row number and never will be.
    ("commit SHA quoted in prose",
     re.compile(r'^[ \t]*#[ \t]*[0-9a-f]{7,40}[.][ \t]')),
    # `#   1. Resolve over DoH.` — a numbered list INSIDE one row's comment
    # (row 11's two probe steps). Section headers use exactly ONE space after
    # `#`; a list item is indented further, and that is the whole difference.
    ("numbered list nested inside a comment",
     re.compile(r'^[ \t]*#[ \t]{2,}')),
    # `# (#114). The mailer's own words ...` — a parenthesised issue reference
    # that happens to open the line.
    ("parenthesised issue reference",
     re.compile(r'^[ \t]*#[ \t]*[(]')),
]

script_text = read(SCRIPT)

def wide_hits(text):
    """Lines whose comment opens with a dotted token containing a digit, and
    which are NOT an accepted row header. Returns (lineno, indent, line)."""
    out = []
    for m in WIDE.finditer(text):
        ls = text.rfind('\n', 0, m.start()) + 1
        le = text.find('\n', m.start())
        line = text[ls:le if le != -1 else len(text)]
        if STRICT.match(line):
            continue
        out.append((text.count('\n', 0, ls) + 1, len(m.group(1)), line))
    return out

# `bare` is every resemblance with NO exemption applied — case 1f measures the
# list against it. `unrecognised` is what survives the list.
bare = wide_hits(script_text)
unrecognised = [(n, i, l) for n, i, l in bare
                if not any(rx.match(l) for _, rx in EXEMPT)]

for lineno, indent, text_line in unrecognised:
    fail(f"{SCRIPT}:{lineno} looks like a row header but is not in the accepted shape "
         f"(indent {indent}): {text_line.strip()[:90]} — if it is a row, the legend cannot "
         f"describe it and no citation can resolve it; if it is prose, add a shape to EXEMPT "
         f"with the reason")

# --- 1f. the exemption list must be load-bearing, and each entry must be.
#     A list that could be deleted without changing the outcome is decoration,
#     and a decorative exemption list is how this check quietly becomes "accept
#     everything", one well-meant entry at a time.
# ⚠️ The size of the exemption SURFACE is pinned, not just its usefulness.
#     Without this the two checks below guard the wrong door: they catch an
#     exemption that is useless, and they catch a list that is empty, but an
#     exemption that is too WIDE passes both — it fires, and the list is not
#     empty, while it quietly swallows a real undocumented row. That is the
#     exact death this check was written to prevent, named in its own PR and
#     then left unguarded (FO-handler [f92b04] demonstrated it on #122 with
#     `re.compile(r'^[ \t]*#[ \t]*1')`, which turned a red `# 17B.` green).
#
#     Raising this number is allowed and sometimes correct — prose does drift
#     into header-like shapes. ⚠️ But raising it ALONE is not enough and must
#     not be: the new line is still unrecognised by 1e, so a narrow EXEMPT
#     shape naming it is required too. Measured, not assumed: adding
#     `# 3rd. …` is red; red with the count raised; green only once a shape
#     names it as well. Both halves on purpose — the widened surface gets a
#     name, and the total gets a human. Neither alone lets it through.
RESEMBLANCES_EXPECTED = 4

if len(bare) != RESEMBLANCES_EXPECTED:
    fail(f"{len(bare)} comment(s) in {SCRIPT} resemble a row header without being one, "
         f"but {RESEMBLANCES_EXPECTED} are accounted for. If you added prose that looks "
         f"like a header, raise RESEMBLANCES_EXPECTED in the same commit and say why; if "
         f"you added a ROW, it is in a shape nothing here recognises. "
         f"Lines: " + "; ".join(f"{n}:{l.strip()[:50]}" for n, _, l in bare))

if not bare:
    fail("the exemption list is not load-bearing: with every exemption ignored the wide "
         "scan still flags nothing, so it proves nothing")
else:
    for reason, rx in EXEMPT:
        if not any(rx.match(l) for _, _, l in bare):
            fail(f"the exemption {reason!r} matches nothing in {SCRIPT} — a rule that "
                 f"cannot fire is indistinguishable from one that was never written, and "
                 f"it will silently widen the day something drifts into its shape")

# --- 1g. the heading's own count must match the table under it. It said
#     "15 items" over a 27-row table — a number that had been wrong for long
#     enough that nobody read it as a claim any more. Same family as everything
#     above: a figure in prose that no longer measures anything, sitting where
#     a reader takes it for a fact.
heading = re.search(r'^##[^\n]*?\((\d+) items\)', read(README), re.M)
if not heading:
    print("cannot measure: the README has no '## ... (N items)' heading to compare"); sys.exit(2)
elif int(heading.group(1)) != len(legend_rows):
    fail(f"the README heading says {heading.group(1)} items over a table of "
         f"{len(legend_rows)} rows — the count drifts every time a check is added, and "
         f"a stale figure in a heading is read as a fact")

# --- 2. every number cited anywhere must be in the legend.
unresolvable = sorted(set(sites) - legend, key=order)
for n in unresolvable:
    where = ", ".join(sorted(set(sites[n]))[:4])
    fail(f"the number {n} is cited but the legend does not define it (cited in: {where})")

# --- 3. positive control: a number that IS defined must not be reported.
#     Without this, "legend == everything" would satisfy 1 and 2 vacuously.
probe = max(legend, key=order)
if probe in unresolvable or probe in missing:
    print(f"cannot measure: control failed — {probe} is in the legend yet was reported"); sys.exit(2)

# --- 4. negative control: a synthetic citation of an undefined number must be
#     caught by the same function that scans the repo. Built in memory, never
#     written into the tree, so this file cannot pollute its own scan.
synthetic = '99' if '99' not in legend else '9907'
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
    # Names what was checked ON EACH SIDE. The previous wording said "no
    # number twice" unconditionally while only the legend had been checked —
    # a pass message that claims more than it verified is worse than none,
    # because it tells the next person that side is already guarded (M3).
    print(f"PASS — legend and script define the SAME {len(legend)} rows, both differences empty; "
          f"no label twice in the legend ({len(legend_rows)} table rows) "
          f"and no label twice in the script ({len(coded_labels)} section headers, any indent); "
          f"{len(sites)} distinct labels cited across the repo, all resolvable; "
          f"scanned that file for `#<token-with-a-digit>. ` at ANY indent and subtracted "
          f"`# <digits><letter?>. `: {len(bare)} resemblances, every one matched by a named "
          f"EXEMPT shape, every EXEMPT shape used, and the count pinned at "
          f"{RESEMBLANCES_EXPECTED}; 0 unrecognised")
    print("       (negative control: a synthetic citation of an undefined number is seen by the same scanner)")
sys.exit(rc)
PY
