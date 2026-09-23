#!/usr/bin/env bash
# Assert that every address in cluster-secrets.sample.yaml is described by the
# name of the object that actually claims it.
#
# ferry133/jg-base#129: the sample told operators CLUSTER_GATEWAY_ADDR was
# envoy-external's LoadBalancer IP. envoy.yaml binds it to envoy-INTERNAL, and
# CLOUDFLARE_GATEWAY_ADDR -- the one that really is envoy-external's -- was
# missing from the sample altogether.
#
# ⚠️ Why it survived, and why the guard is worth more than the fix: on an
# **appliance** envoy-internal and k8s-gateway share one address through
# `lbipam.cilium.io/sharing-key`, so filling this in wrong produces NO symptom.
# Only `full` / `prosumer`, which separate them, can tell. An error that cannot
# produce a symptom on most deployments, and a correct setting, look the same
# on those deployments -- so nothing was ever going to report this, and the
# operator is the one who pays.
#
# This file is what an operator fills in by hand, so its comments are the
# product, not documentation of the product (~/coding/CLAUDE.md, 2026-09-16).
#
# Usage: scripts/check-sample-addr-comments.sh
#   exit 0 every address names its claimant, 1 one did not, 2 cannot measure
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE="$ROOT/kubernetes/components/sops/cluster-secrets.sample.yaml"
NETDIR="$ROOT/kubernetes/apps/base/network"
[[ -r "$SAMPLE" ]] || { echo "cannot measure: $SAMPLE not readable"; exit 2; }
[[ -d "$NETDIR"  ]] || { echo "cannot measure: $NETDIR not found"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "cannot measure: python3 is missing"; exit 2; }

python3 - "$SAMPLE" "$NETDIR" <<'PY'
import sys, os, re

sample, netdir = sys.argv[1], sys.argv[2]
text = open(sample, encoding="utf-8").read()

# Each `NAME: "value"` line in the sample, with everything commented after it
# up to the next key -- the comment may be wrapped over several lines, and a
# single-line grep would read a wrapped sentence as absent (this repo has been
# bitten by exactly that).
entries, cur = {}, None
for line in text.split("\n"):
    m = re.match(r'^\s{2}([A-Z][A-Z0-9_]*):\s', line)
    if m:
        cur = m.group(1)
        entries[cur] = line.split('#', 1)[1] if '#' in line else ''
    elif cur and re.match(r'^\s+#', line):
        entries[cur] += ' ' + line.split('#', 1)[1]
    elif line.strip() and not line.strip().startswith('#'):
        cur = None

addrs = sorted(k for k in entries if k.endswith('_ADDR'))
if not addrs:
    print("cannot measure: the sample declares no *_ADDR keys, so 'all correct' would be vacuous")
    sys.exit(2)

# Where is each one actually claimed? Nearest preceding `name:` to the
# reference -- which is what a person reading the manifest does.
claims = {}
for dirpath, _, files in os.walk(netdir):
    for fn in files:
        if not fn.endswith(('.yaml', '.yml')):
            continue
        path = os.path.join(dirpath, fn)
        lines = open(path, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            for a in addrs:
                if '${' + a in line and 'lbipam.cilium.io/ips' in line:
                    owner = None
                    for j in range(i, -1, -1):
                        # `(?:&\S+\s+)?` and not `&?\w*`: the latter eats the
                        # first half of `envoy-internal` and returns `-internal`,
                        # which then "matches" any comment containing the full
                        # name -- a substring check that passes for the wrong
                        # reason reads exactly like one that passes.
                        mm = re.match(r'^\s*(?:-\s+)?name:\s*(?:&\S+\s+)?([\w.-]+)\s*$', lines[j])
                        if mm:
                            owner = mm.group(1); break
                    claims.setdefault(a, []).append(
                        (os.path.relpath(path, os.path.dirname(netdir)), i + 1, owner))

rc = 0
def fail(m):
    global rc
    print("FAIL — " + m); rc = 1

# Instrument control: at least one address must be found in the manifests, or
# "every comment matches" is a statement about an empty set.
if not claims:
    print("cannot measure: no *_ADDR is referenced by an lbipam.cilium.io/ips line "
          "under the network directory, so nothing was compared")
    sys.exit(2)

for a in addrs:
    comment = entries[a]
    if a not in claims:
        # Not claimed anywhere -- the sample must SAY so rather than imply a
        # binding that does not exist.
        if not re.search(r'\bNO\b.*manifest|no jg-base manifest|not.*consume', comment, re.I):
            fail(f"{a} is not claimed by any lbipam.cilium.io/ips under network/, and its "
                 f"comment does not say so: '{comment.strip()[:70]}' — an operator fills it in "
                 f"and then cannot find what reads it")
        continue
    owners = {o for _, _, o in claims[a] if o}
    if not owners:
        fail(f"{a} is referenced but the owning object's name could not be read back")
        continue
    if not any(o in comment for o in owners):
        fail(f"{a} is claimed by {sorted(owners)} "
             f"({claims[a][0][0]}:{claims[a][0][1]}) but the sample calls it "
             f"'{comment.strip()[:70]}' — the operator fills this in by hand, and on an "
             f"appliance a wrong value produces no symptom at all")

# ⚠️ The other direction, which is the defect this file actually had: an
# address that IS claimed under network/ but is absent from the sample. The
# loop above only walks what the sample declares, so a missing line is
# invisible to it -- and "missing" is what CLOUDFLARE_GATEWAY_ADDR was.
declared_anywhere = set()
for dirpath, _, files in os.walk(netdir):
    for fn in files:
        if not fn.endswith(('.yaml', '.yml')):
            continue
        for line in open(os.path.join(dirpath, fn), encoding="utf-8"):
            if 'lbipam.cilium.io/ips' in line:
                declared_anywhere |= set(re.findall(r'\$\{([A-Z][A-Z0-9_]*_ADDR)', line))
missing = sorted(declared_anywhere - set(entries))
for a in missing:
    fail(f"{a} is claimed by an lbipam.cilium.io/ips under network/ but the sample never "
         f"mentions it — the operator has no line to fill in, and the address silently "
         f"falls back to whatever default the manifest carries")

if rc == 0:
    print(f"PASS — {len(addrs)} address(es) in the sample; "
          f"{len(claims)} claimed under network/ and each names its claimant "
          f"({', '.join(sorted(claims))}); the rest say they are claimed by nothing")
sys.exit(rc)
PY
