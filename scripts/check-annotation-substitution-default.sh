#!/usr/bin/env bash
# Assert that no annotation value can render EMPTY after Flux postBuild
# substitution.
#
# ferry133/jg-base#103: `im` carried
#   jg-base.jiahd.cc/omni-sa-key-expires: "${TALOS_MCP_SA_KEY_EXPIRES:-}"
# On a cluster that holds no talos-mcp key the variable is empty -- which is
# the CORRECT state, not a data gap -- so the value substituted to nothing.
# kustomize had already emitted the scalar unquoted (it strips quotes that are
# not needed to preserve the type, and `${VAR:-}` is a plain string), so the
# rendered line was `...expires:` with nothing after the colon. YAML reads that
# as null, and app-template's deployment class rejects it:
#
#   _deployment.tpl:32:36 executing "bjw-s.common.class.deployment" at <$value>:
#     wrong type for value; expected string; got interface {}
#
# The HelmRelease stayed UpgradeFailed for 31 hours. Two further copies of the
# same shape were latent in extras/factory (FACTORY_OMNI_SA_KEY_EXPIRES,
# FACTORY_GITHUB_TOKEN_EXPIRES); they had simply never met a cluster where
# those values were unset.
#
# The fix is a default that is itself a quoted empty string, `${VAR:-""}`:
# envsubst inserts the two literal quote characters, YAML reads `""`, and the
# value is an empty STRING. daily-check row 24 already treats "absent" and
# "empty string" identically (configmap.yaml:1360 `(... // "") != ""`), so the
# monitoring side is unchanged.
#
# What this guard asserts is the source property that makes that safe: an
# annotation value must still be non-empty when every variable in it is unset.
# A literal prefix (`external.${SECRET_DOMAIN}`) or a non-empty default
# (`${X:=0.0.0.0}`) satisfies it; an empty default does not.
#
# Deliberately a text check and not a render: a guard needing kustomize and
# flux would exit "cannot measure" on every CI run, which reads the same as
# passing. The render behaviour is measured and recorded; what regresses is
# the source.
#
# Usage: scripts/check-annotation-substitution-default.sh
#   exit 0 no value can render empty, 1 one can, 2 cannot measure here
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null || { echo "cannot measure: python3 not found"; exit 2; }

python3 - "$ROOT" <<'PY'
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
SUB = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::([-=])([^}]*))?\}')

def can_render_empty(value: str):
    """Replace each ${...} by what it yields when the variable is unset,
    then ask whether anything non-blank is left."""
    def repl(m):
        _, op, default = m.group(1), m.group(2), m.group(3)
        return default if op else ''        # no default -> empty when unset
    return repl and SUB.sub(repl, value).strip() == ''

def annotation_values(text):
    """Yield (lineno, key, value) for mapping entries inside an `annotations:`
    block. Comment lines are skipped -- scripts embedded in ConfigMaps discuss
    ${...} in prose and are not annotations."""
    in_ann, ind = False, 0
    for n, line in enumerate(text.split('\n'), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        cur = len(line) - len(line.lstrip())
        if re.match(r'^\s*annotations:\s*$', line):
            in_ann, ind = True, cur
            continue
        if in_ann and cur <= ind:
            in_ann = False
        if in_ann:
            m = re.match(r'^\s*([^:#\s][^:]*):\s*(.+?)\s*$', line)
            if m:
                yield n, m.group(1), m.group(2).strip('"\'')

findings, scanned = [], 0
for f in sorted(root.rglob('*.y*ml')):
    if '.git' in f.parts: continue
    try: text = f.read_text()
    except Exception: continue
    scanned += 1
    for n, key, val in annotation_values(text):
        if '${' in val and can_render_empty(val):
            findings.append((f.relative_to(root), n, key, val))

# --- controls: the analyser must say yes to one and no to the other ---
assert can_render_empty('${X:-}'),            'CONTROL FAILED: empty default not detected'
assert can_render_empty('${X}'),              'CONTROL FAILED: absent default not detected'
assert not can_render_empty('${X:=0.0.0.0}'), 'CONTROL FAILED: non-empty default misread'
assert not can_render_empty('external.${X}'), 'CONTROL FAILED: literal prefix misread'
print(f"controls ok (empty/absent detected, non-empty default and literal prefix cleared); {scanned} files scanned")

if findings:
    print(f"\nFAIL — {len(findings)} annotation value(s) can render empty, which YAML reads as null:")
    for rel, n, key, val in findings:
        print(f"  {rel}:{n}\n      {key}: {val}\n      -> use a non-empty default, e.g. {val.replace(':-}', ':-\"\"}')}")
    sys.exit(1)
print("ok — every substituted annotation value still renders non-empty when its variables are unset")
PY
