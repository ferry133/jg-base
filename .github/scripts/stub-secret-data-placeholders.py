#!/usr/bin/env python3
"""Replace Flux `${VAR}` placeholders in Secret `data:` fields with an empty value.

Why this exists
---------------
`flux-local` builds every Flux Kustomization by shelling out to
`flux build ks ... --dry-run`, and the flux CLI says of that mode:

    Note that variable substitutions from Secrets and ConfigMaps are skipped
    in dry-run mode.

So the literal `${TALOS_MCP_CONFIG_B64:-}` survives into the built Secret. flux
then runs `maskBase64EncryptedSopsData`, which base64-decodes *every* `data:`
value looking for sops ciphertext, and hard-fails on the first invalid byte
(fluxcd/flux2 `internal/build/build.go`, unchanged on main as of 2026-08-23):

    data, err := base64.StdEncoding.DecodeString(v)
    if corruptErr := base64.CorruptInputError(0); errors.As(err, &corruptErr) {
        return corruptErr
    }

`$` is not in the base64 alphabet, so the decode fails at byte 0 and the whole
`flux build` fails. In flux-local that surfaces during *collection*, so the run
ends with `no tests ran` — every other Kustomization in the repo goes
unvalidated too.

There is no way out via configuration. No Flux substitution syntax is
base64-safe (`$`, `{`, `}` are all outside the alphabet), and `flux-local`
always uses `flux build`, so the placeholder cannot reach `data:` and survive.
Moving the value to `stringData:` is not equivalent either: the mounted file
would then contain the base64 text instead of the decoded talosconfig.

What this does NOT cost us
--------------------------
flux-local discards Secret contents anyway — `--skip-secrets` defaults to true
("do not include Secrets to reduce output size and randomness"). This script
only removes a build-time artifact the tool could never represent; it does not
narrow what CI checks. The real manifests are untouched in git.

Guard
-----
`--check` fails if the tree still contains a placeholder in a Secret `data:`
field, which is what CI runs *after* the rewrite to prove the rewrite happened.
A rewrite that silently matched nothing reads exactly like one that worked.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# A mapping entry: leading indent, key, value. Values here are always scalars.
ENTRY = re.compile(r"^(?P<indent>\s+)(?P<key>[A-Za-z0-9_.\-]+):(?P<sep>\s*)(?P<value>.*)$")
PLACEHOLDER = re.compile(r"\$\{[^}]*\}")


def _rewrite(text: str) -> tuple[str, list[tuple[int, str]]]:
    """Return (new_text, [(line_number, key), ...]) for one file."""
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    hits: list[tuple[int, str]] = []

    # Per-document state. A file may hold several documents.
    is_secret = False
    in_data = False
    data_indent = 0

    for lineno, line in enumerate(lines, start=1):
        stripped = line.rstrip("\n")

        if stripped.startswith("---"):
            is_secret, in_data = False, False
            out.append(line)
            continue

        if re.match(r"^kind:\s*Secret\s*$", stripped):
            is_secret = True
            out.append(line)
            continue

        if is_secret and re.match(r"^data:\s*$", stripped):
            in_data, data_indent = True, 0
            out.append(line)
            continue

        if in_data:
            # A non-blank, non-comment line at or below the block's own indent
            # ends the block (`stringData:`, `type:`, the next document, ...).
            bare = stripped.strip()
            if bare and not bare.startswith("#"):
                indent = len(stripped) - len(stripped.lstrip())
                if indent <= data_indent:
                    in_data = False
                    out.append(line)
                    continue

            m = ENTRY.match(stripped)
            if m and PLACEHOLDER.search(m.group("value")):
                out.append(f'{m.group("indent")}{m.group("key")}: ""\n')
                hits.append((lineno, m.group("key")))
                continue

        out.append(line)

    return "".join(out), hits


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("roots", nargs="*", default=["kubernetes"], help="directories to walk")
    ap.add_argument(
        "--check",
        action="store_true",
        help="do not write; exit 1 if any Secret data: placeholder is still present",
    )
    args = ap.parse_args()

    total = 0
    for root in args.roots:
        for path in sorted(Path(root).rglob("*.yaml")):
            text = path.read_text()
            if "${" not in text:
                continue
            new, hits = _rewrite(text)
            for lineno, key in hits:
                total += 1
                verb = "still present" if args.check else "stubbed"
                print(f"{verb}: {path}:{lineno} data.{key}")
            if hits and not args.check:
                path.write_text(new)

    if args.check:
        if total:
            print(
                f"\n{total} Flux placeholder(s) remain in Secret data: fields — "
                "`flux build --dry-run` will fail to base64-decode them.",
                file=sys.stderr,
            )
            return 1
        print("no Flux placeholders in Secret data: fields")
        return 0

    print(f"\n{total} placeholder(s) stubbed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
