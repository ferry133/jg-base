#!/usr/bin/env bash
# Every literal ${X} under kubernetes/ is a promise that Flux postBuild will
# substitute it with a cluster-secrets value. ferry133/jg-base#69/#70: the
# base im init referenced the CONTAINER variable ${ALLOWED_EMAILS}, postBuild
# rewrote it to "" (no such key exists), and every cluster's terminal locked
# everyone out behind three green signals — the second instance of the shape
# monitoring/backup's D46 recorded for ConfigMaps.
#
# This guard makes the promise explicit, both ways:
#   - every ${X} found must be declared in scripts/substitution-vocabulary.txt
#     (adding a name is a reviewed diff; a runtime variable is written $${X}
#     and never listed)
#   - every declared name must still be used somewhere — a stale entry is a
#     standing exemption for the next accident that happens to pick that name
#
# Exempt: whole documents annotated kustomize.toolkit.fluxcd.io/substitute:
# disabled (their ${X} are runtime by declaration), YAML comment lines (a
# substitution inside a comment stays a comment), and $${X} escapes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
vocab_file = root / "scripts" / "substitution-vocabulary.txt"
if not vocab_file.exists():
    sys.exit(f"missing {vocab_file}")
vocab = {
    line.strip()
    for line in vocab_file.read_text().splitlines()
    if line.strip() and not line.startswith("#")
}

VAR = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)(?::[-=+][^}]*)?\}")
ANNOT = re.compile(r"kustomize\.toolkit\.fluxcd\.io/substitute:\s*\"?disabled\"?")

used = {}          # name -> [locations]
for f in sorted(root.glob("kubernetes/**/*.yaml")):
    lines = f.read_text().splitlines()
    # split into documents on standalone --- lines, keeping line offsets
    docs, start = [], 0
    for i, l in enumerate(lines):
        if l.strip() == "---":
            docs.append((start, i)); start = i + 1
    docs.append((start, len(lines)))
    rel = f.relative_to(root)
    for lo, hi in docs:
        doc = lines[lo:hi]
        if any(ANNOT.search(l) for l in doc):
            continue
        for j, l in enumerate(doc):
            if l.lstrip().startswith("#"):
                continue
            for m in VAR.finditer(l):
                used.setdefault(m.group(1), []).append(f"{rel}:{lo + j + 1}")

unknown = {n: locs for n, locs in used.items() if n not in vocab}
stale = vocab - used.keys()

failed = False
if unknown:
    failed = True
    print("UNDECLARED substitution variables — either add to")
    print("scripts/substitution-vocabulary.txt (a reviewed decision) or, if the")
    print("container is supposed to read it at runtime, write it as $${X}:")
    for n in sorted(unknown):
        for loc in unknown[n][:3]:
            print(f"  ${{{n}}}  {loc}")
        if len(unknown[n]) > 3:
            print(f"  ${{{n}}}  … and {len(unknown[n]) - 3} more")
if stale:
    failed = True
    print("STALE vocabulary entries — no longer used anywhere; remove them,")
    print("or the next accidental ${X} that picks one of these names passes:")
    for n in sorted(stale):
        print(f"  {n}")

if failed:
    sys.exit(1)
print(f"ok — {len(used)} substitution names in use, all declared; no stale entries")
PY
