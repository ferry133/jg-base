#!/usr/bin/env python3
"""Resolve Flux `${VAR:=default}` placeholders in Kustomization `spec.path` to their default.

Why this exists
---------------
`flux-local` walks Flux Kustomizations and builds each one, and `flux build ks
... --dry-run` skips variable substitution. A `spec.path` carrying a `${...}`
therefore reaches the filesystem literally, and flux-local aborts *collection*:

    ERROR: Kustomization 'flux-system/claudecode-postgres-backup' path field
    'kubernetes/apps/extras/claudecode/postgres/backup/${NAS_BACKUP:=nfs}'
    is not a directory

That is a hard stop for the whole run, not one failed test — same blast radius
as the Secret `data:` problem that `stub-secret-data-placeholders.py` handles,
and the reason `kubernetes/apps/extras/**` could not be walked by CI at all
(ferry133/jg-base#37).

`base/storage/longhorn/backup-ks.yaml` records the other half of this: it
deliberately does NOT use a `${...}` path, using `suspend` as its gate instead,
because the variable form "kills CI". Its comment says the extras precedent
"survives only because extras are unreachable from apps/base and CI has never
walked one — untested, not proven". This script is what makes it testable.

What it substitutes, and what that does NOT cover
-------------------------------------------------
`${VAR:=default}` becomes `default` — the value a cluster that never sets VAR
would get, so CI exercises the shipping default.

**The non-default variants are therefore NOT covered.** For
`${NAS_BACKUP:=nfs}` this run tests `backup/nfs/` and never `backup/none/`.
That is a real gap and it is stated here rather than left to be discovered:
a cluster selecting `none` is running a directory no CI job has ever built.
Covering it needs a second run with a different substitution, which is not
done today.

`${VAR}` with no default is a hard error rather than a guess. There is no
honest value to put there — any choice would build one arbitrary variant while
reporting on all of them.

Guard
-----
`--check` fails if any `${...}` remains in a Kustomization `spec.path`, which is
what CI runs *after* the rewrite to prove the rewrite happened. A rewrite that
silently matched nothing reads exactly like one that worked.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# `path:` under a Kustomization spec. Value may be quoted or bare.
PATH_LINE = re.compile(r"^(?P<indent>\s*)path:(?P<sep>\s*)(?P<quote>[\"']?)(?P<value>.*?)(?P=quote)\s*$")
WITH_DEFAULT = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):=([^}]*)\}")
ANY_PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def _is_kustomization(text: str) -> bool:
    return "kind: Kustomization" in text and "kustomize.toolkit.fluxcd.io" in text


def _rewrite(text: str) -> tuple[str, list[tuple[int, str, str]]]:
    out, changed = [], []
    for n, line in enumerate(text.splitlines(keepends=True), start=1):
        m = PATH_LINE.match(line.rstrip("\n"))
        if not m or not ANY_PLACEHOLDER.search(m.group("value")):
            out.append(line)
            continue
        before = m.group("value")
        after = WITH_DEFAULT.sub(lambda mm: mm.group(2), before)
        if ANY_PLACEHOLDER.search(after):
            raise SystemExit(
                f"{n}: path placeholder without a default has no honest "
                f"substitution: {before}"
            )
        nl = "\n" if line.endswith("\n") else ""
        out.append(f"{m.group('indent')}path:{m.group('sep')}{m.group('quote')}{after}{m.group('quote')}{nl}")
        changed.append((n, before, after))
    return "".join(out), changed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--check", action="store_true", help="fail if a placeholder remains")
    args = ap.parse_args()

    remaining, stubbed = [], 0
    for root in args.paths:
        for f in sorted(Path(root).rglob("*.yaml")):
            text = f.read_text()
            if not _is_kustomization(text):
                continue
            if args.check:
                for n, line in enumerate(text.splitlines(), start=1):
                    m = PATH_LINE.match(line)
                    if m and ANY_PLACEHOLDER.search(m.group("value")):
                        remaining.append(f"{f}:{n} {m.group('value')}")
                continue
            new, changed = _rewrite(text)
            if changed:
                f.write_text(new)
                for n, before, after in changed:
                    print(f"stubbed: {f}:{n} {before} -> {after}")
                stubbed += len(changed)

    if args.check:
        if remaining:
            print(f"\n{len(remaining)} placeholder(s) remain in Kustomization spec.path:")
            for r in remaining:
                print(f"  still present: {r}")
            return 1
        print("no Flux placeholders in Kustomization spec.path")
        return 0

    print(f"\n{stubbed} path placeholder(s) stubbed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
