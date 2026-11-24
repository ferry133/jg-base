#!/usr/bin/env bash
# Every image reference under kubernetes/ is pinned by digest.
#
# ferry133/jg-base#220. CLAUDE.md said `im` is pinned by `tag@digest` "like
# everything else here", and at main@eb5c3b2 that was false: postgres:16 and
# alpine:3.20 ran on rolling tags, three more images on version tags, and no
# check anywhere looked. The reason from #66 applies to every image: on a
# spegel cluster a mutable tag resolves to whichever node cached it first.
# Measured 2026-11-24, before this guard existed: `postgres:16` was 16.13 on
# one production cluster and 16.14 on the other, and 16.16 at the registry.
#
# Rule (ferry133, 2026-11-24, on #220): every image in base is written
# `tag@sha256:<64 hex>`; a CI guard refuses anything else; an image whose tag
# the manifest does not write goes on an allowlist with a reason, and the
# allowlist's length is pinned. Chart OCIRepository tags are out of scope.
#
# ── What this guard reads, and what it cannot see ──────────────────────────
#
# It parses every tracked-or-not *.yaml / *.yml under kubernetes/ with yq and
# looks at each `image` KEY, at any depth, in two shapes:
#
#   image: repo:tag@sha256:…                 (a string)
#   image: { repository: …, tag: …@sha256:… }  (Helm values; `digest:` also
#                                               counts when it is sha256:…)
#
# It does NOT see:
#   - an image a chart supplies from its own defaults (no `image` key here);
#   - an image under any other key name (`imageRepository`, a `--image=` flag
#     inside a script string, a kustomize `images:` transformer);
#   - OCIRepository / HelmRepository chart versions (out of scope by ruling);
#   - anything in Markdown.
# A green run says nothing about those.
#
# It reads the files, not the cluster. Nothing between these files and the
# pod rewrites an image string today (no kustomize `images:` transformer; the
# two `im` components copy the app container's pinned tag — see ALLOW below).
#
# ── Exit codes ─────────────────────────────────────────────────────────────
#   0  every reference found is pinned, and the allowlist is exact
#   1  a reference is not pinned, or the allowlist is wrong
#   2  cannot measure (yq missing, a file does not parse, the reader's own
#      control fails, or zero references were found)
# Red wins over cannot-measure only where both are known; a reader that
# cannot be trusted reports 2 and stops before judging anything.
#
# Usage: scripts/check-image-pins.sh              (the guard)
#        scripts/check-image-pins.sh --self-test  (cell 0 + mutations)

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
ROOT="${IMAGE_PIN_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}"
SCAN="kubernetes"

# ── Allowlist: an `image: {repository: …}` map with NO tag and NO digest ────
#
# Only that one shape can be allowlisted. A string image, or a map whose tag
# lacks a digest, cannot be excused here at all.
#
# One entry per line: <file relative to repo root>|<yq path of the image map>|<reason>
# Every entry must match a reference that exists (an unused entry is red), and
# the number of entries must equal ALLOW_PINNED_TOTAL. To add one: add the line
# with its reason AND raise the number — both halves, in the same change. The
# number is there so the list cannot grow one harmless entry at a time into
# "everything is accepted".
ALLOW_PINNED_TOTAL=3
ALLOW='
kubernetes/apps/base/kube-system/coredns/app/helmrelease.yaml|spec.values.image|tag comes from the coredns chart appVersion; the chart version is what is pinned (OCIRepository), out of scope by the #220 ruling
kubernetes/apps/base/claudecode/claude-code/im/chamber/bridge.yaml|spec.values.controllers.im.containers.chamber-bridge.image|tag is copied from the app container pin by the component replacement; check-chamber-component.sh asserts they are equal
kubernetes/apps/base/claudecode/claude-code/im/netdev/netdev-mcp.yaml|spec.values.controllers.im.containers.netdev-mcp.image|tag is copied from the app container pin by the replacement in im/netdev/kustomization.yaml
'

TAB="$(printf '\t')"
PIN_RE='@sha256:[0-9a-f]{64}$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'

cannot() { echo "cannot measure: $*"; exit 2; }

command -v yq >/dev/null 2>&1 || cannot "yq required. CI installs it, pinned, in the 'scripts' job of .github/workflows/flux-local.yaml."

# Emits one line per `image` key found in one file:
#   S <TAB> path <TAB> value                       string form
#   M <TAB> path <TAB> repository <TAB> tag <TAB> digest   map form
#   X <TAB> path <TAB> yaml-tag                    anything else under `image`
#                                                  that is not a map (null, int…)
# A map under `image` without `repository` is not an image reference (a CRD
# schema's `properties.image`, for one) and is not emitted.
read_images() {
  # The separator reaches yq through the environment, not as "\t" in the
  # expression: yq 4.48.1 (the version CI pins) prints that escape literally,
  # where 4.52 prints a tab. The reader control below is what caught it.
  SEP="$TAB" yq -r '
    .. | select(tag == "!!map" and has("image")) | .image |
    (
      (select(tag == "!!str") | "S" + strenv(SEP) + (path | join(".")) + strenv(SEP) + .),
      (select(tag == "!!map" and has("repository")) |
         "M" + strenv(SEP) + (path | join(".")) + strenv(SEP) + (.repository | tostring) + strenv(SEP) +
         ((.tag // "") | tostring) + strenv(SEP) + ((.digest // "") | tostring)),
      (select(tag != "!!str" and tag != "!!map") | "X" + strenv(SEP) + (path | join(".")) + strenv(SEP) + tag)
    )
  ' "$1"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/image-pins.XXXXXX")" || cannot "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ── --self-test ────────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  [ -d "$ROOT/$SCAN" ] || cannot "no $SCAN/ under $ROOT"
  fails=0
  # run <name> <want-rc> <want-text-or-empty> <root> [script]
  run() {
    local name="$1" want="$2" text="$3" root="$4" script="${5:-$SELF}" out rc
    set +e
    out="$(IMAGE_PIN_ROOT="$root" bash "$script" 2>&1)"; rc=$?
    set -e
    if [ "$rc" != "$want" ]; then
      echo "CELL FAIL  $name: rc=$rc, wanted $want"; echo "$out" | sed 's/^/    | /' | head -12
      fails=$((fails + 1)); return
    fi
    if [ -n "$text" ] && ! printf '%s\n' "$out" | grep -qF -- "$text"; then
      echo "CELL FAIL  $name: rc=$rc as wanted, but not for the stated reason (no line contains: $text)"
      echo "$out" | sed 's/^/    | /' | head -12
      fails=$((fails + 1)); return
    fi
    echo "cell ok    $name (rc=$rc${text:+; reason line contains: $text})"
  }
  fresh() { rm -rf "$WORK/m"; mkdir -p "$WORK/m"; cp -R "$ROOT/$SCAN" "$WORK/m/$SCAN" || cannot "could not copy $SCAN/ for a mutation"; }
  # mutate <file relative to root> <sed program>; refuses a mutation that changed nothing
  mutate() {
    local f="$WORK/m/$1" before after
    [ -f "$f" ] || cannot "mutation target missing: $1"
    before="$(cksum < "$f")"
    sed "$2" "$f" > "$f.new" && mv "$f.new" "$f"
    after="$(cksum < "$f")"
    [ "$before" != "$after" ] || cannot "mutation did not apply to $1 ($2) — an unapplied mutation and an uncaught one both read rc=0"
  }

  B="$SCAN/apps/base"

  # Cell 0: no mutation. If this is red, every cell below would be red too and
  # would read as "every mutation was caught".
  fresh; run "0  unmutated copy" 0 "" "$WORK/m"

  fresh; mutate "$B/claudecode/postgres/app/deployment.yaml" 's/^\( *image: postgres:[^@]*\)@sha256:.*$/\1/'
  run "1  string image loses its digest" 1 "claudecode/postgres/app/deployment.yaml" "$WORK/m"

  fresh; mutate "$B/default/echo/app/helmrelease.yaml" 's/^\( *tag: [^@]*\)@sha256:.*$/\1/'
  run "2  values tag loses its digest" 1 "default/echo/app/helmrelease.yaml" "$WORK/m"

  fresh; mutate "$B/network/cloudflare-tunnel/app/helmrelease.yaml" '/^ *tag: .*@sha256:/d'
  run "3  tag line deleted outright" 1 "no tag and no digest, and is not on the allowlist" "$WORK/m"

  fresh; mutate "$B/monitoring/daily-check/app/cronjob.yaml" 's/^\( *image: .*@sha256:[0-9a-f]\{63\}\)[0-9a-f]$/\1/'
  run "4  digest one hex digit short" 1 "monitoring/daily-check/app/cronjob.yaml" "$WORK/m"

  fresh; mutate "$B/network/lan-address/app/deployment.yaml" 's/^\( *image: \).*$/\1alpine:latest/'
  run "5  rolling tag, no digest" 1 "network/lan-address/app/deployment.yaml" "$WORK/m"

  fresh; mkdir -p "$WORK/m/$B/zz-new/deep/er"
  printf 'apiVersion: batch/v1\nkind: Job\nmetadata: {name: x}\nspec:\n  template:\n    spec:\n      initContainers:\n        - name: i\n          image: busybox:1.36\n      containers:\n        - name: c\n          image: busybox:1.36@sha256:%064d\n' 0 > "$WORK/m/$B/zz-new/deep/er/job.yaml"
  run "6  new file, initContainer unpinned (the walk is by key, not by a file list)" 1 "zz-new/deep/er/job.yaml: spec.template.spec.initContainers.0.image" "$WORK/m"

  fresh; mutate "$B/kube-system/coredns/app/helmrelease.yaml" 's/^\( *repository: mirror\.gcr\.io\/coredns\/coredns\)$/\1\
      tag: 1.13.1@sha256:9b9128672209474da07c91439bf15ed704ae05ad918dd6454e5b6ae14e35fee6/'
  run "7  allowlisted image gains a pin, entry no longer used" 1 "allowlist entry matches no untagged image" "$WORK/m"

  # 8 and 9 mutate a copy of this script: the allowlist lives in it.
  fresh; mutate "$B/default/echo/app/helmrelease.yaml" '/^ *tag: .*@sha256:/d'
  sed 's#^ALLOW=.$#&\
kubernetes/apps/base/default/echo/app/helmrelease.yaml|spec.values.controllers.echo.containers.app.image|added without raising the number#' "$SELF" > "$WORK/s8.sh"
  cmp -s "$SELF" "$WORK/s8.sh" && cannot "script mutation 8 did not apply"
  run "8  allowlist grows by one, number not raised" 1 "ALLOW_PINNED_TOTAL" "$WORK/m" "$WORK/s8.sh"

  fresh
  sed 's/^ALLOW_PINNED_TOTAL=3$/ALLOW_PINNED_TOTAL=4/' "$SELF" > "$WORK/s9.sh"
  cmp -s "$SELF" "$WORK/s9.sh" && cannot "script mutation 9 did not apply"
  run "9  number raised, no entry added" 1 "ALLOW_PINNED_TOTAL" "$WORK/m" "$WORK/s9.sh"

  fresh; printf 'a: [unclosed\n  b: {\n' > "$WORK/m/$B/default/echo/app/broken.yaml"
  run "10 a file that does not parse" 2 "does not parse" "$WORK/m"

  # A reader that returns nothing must not read as "nothing is unpinned".
  fresh; mkdir -p "$WORK/blind"; printf '#!/bin/sh\nexit 0\n' > "$WORK/blind/yq"; chmod +x "$WORK/blind/yq"
  set +e; out="$(PATH="$WORK/blind:$PATH" IMAGE_PIN_ROOT="$WORK/m" bash "$SELF" 2>&1)"; rc=$?; set -e
  if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -qF "reader control"; then
    echo "cell ok    11 blind reader (rc=2; reason line contains: reader control)"
  else
    echo "CELL FAIL  11 blind reader: rc=$rc, wanted 2 with 'reader control'"; fails=$((fails + 1))
  fi

  fresh; rm -rf "$WORK/m/$SCAN/apps"
  run "12 nothing to read (apps/ removed)" 2 "zero image references" "$WORK/m"

  if [ "$fails" -ne 0 ]; then echo "SELF-TEST FAIL: $fails cell(s) did not behave as stated"; exit 1; fi
  echo "self-test ok: 13 cells (cell 0 unmutated = green; 9 mutations red for the stated reason; 3 cannot-measure cells = 2)"
  exit 0
fi

# ── Gate the reader before trusting any of its output ──────────────────────
# One document per shape it must tell apart. yq differs between versions, and
# a reader that silently returns less reads as "fewer images", never as broken.
cat > "$WORK/control.yaml" <<'EOF'
kind: Deployment
spec:
  template:
    spec:
      initContainers:
        - name: a
          image: one:1
      containers:
        - name: b
          image: two:2@sha256:0000000000000000000000000000000000000000000000000000000000000000
---
kind: HelmRelease
spec:
  values:
    image:
      repository: three
      tag: 3
    other:
      image:
        repository: four
    schema:
      properties:
        image:
          type: string
    broken:
      image: null
EOF
got="$(read_images "$WORK/control.yaml" 2>/dev/null | cut -f1,2 | tr '\t' ' ' | sort | tr '\n' ';')" || true
want="M spec.values.image;M spec.values.other.image;S spec.template.spec.containers.0.image;S spec.template.spec.initContainers.0.image;X spec.values.broken.image;"
[ "$got" = "$want" ] || cannot "reader control failed — yq did not return the five references planted in a fixture.
  wanted: $want
  got:    $got"

# ── Read the tree ──────────────────────────────────────────────────────────
[ -d "$ROOT/$SCAN" ] || cannot "no $SCAN/ under $ROOT"
find "$ROOT/$SCAN" -type f \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort > "$WORK/files"
nfiles="$(wc -l < "$WORK/files" | tr -d ' ')"
[ "$nfiles" -gt 0 ] || cannot "zero YAML files under $SCAN/"

: > "$WORK/refs"
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  if ! read_images "$f" > "$WORK/one" 2> "$WORK/err"; then
    cannot "$rel does not parse: $(head -1 "$WORK/err")"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s\t%s\n' "$rel" "$line" >> "$WORK/refs"
  done < "$WORK/one"
done < "$WORK/files"

nrefs="$(wc -l < "$WORK/refs" | tr -d ' ')"
[ "$nrefs" -gt 0 ] || cannot "zero image references found in $nfiles files under $SCAN/ — that is a reader or a path problem, not a clean tree"

# ── Judge ──────────────────────────────────────────────────────────────────
bad=0; n_str=0; n_map=0; n_allow=0
: > "$WORK/untagged"
while IFS="$TAB" read -r rel kind path a b c; do
  case "$kind" in
    S)
      if printf '%s' "$a" | grep -Eq "$PIN_RE"; then n_str=$((n_str + 1)); else
        echo "NOT PINNED  $rel: $path = $a   (want repo:tag@sha256:<64 hex>)"; bad=$((bad + 1)); fi ;;
    M)
      if printf '%s' "$b" | grep -Eq "$PIN_RE" || printf '%s' "$c" | grep -Eq "$DIGEST_RE"; then
        n_map=$((n_map + 1))
      elif [ -z "$b" ] && [ -z "$c" ]; then
        printf '%s|%s\n' "$rel" "$path" >> "$WORK/untagged"
      else
        echo "NOT PINNED  $rel: $path = $a, tag '$b'   (want tag: <tag>@sha256:<64 hex>)"; bad=$((bad + 1))
      fi ;;
    X)
      echo "NOT PINNED  $rel: $path is $a, neither an image string nor a {repository, tag} map"; bad=$((bad + 1)) ;;
    *) cannot "reader emitted a line this script does not understand: $kind" ;;
  esac
done < "$WORK/refs"

printf '%s\n' "$ALLOW" | sed '/^$/d' > "$WORK/allow"
n_entries="$(wc -l < "$WORK/allow" | tr -d ' ')"
if [ "$n_entries" != "$ALLOW_PINNED_TOTAL" ]; then
  echo "ALLOWLIST   has $n_entries entries and ALLOW_PINNED_TOTAL is $ALLOW_PINNED_TOTAL. Adding an entry takes both halves: the line with its reason, and the number."
  bad=$((bad + 1))
fi
while IFS='|' read -r afile apath areason; do
  [ -n "$areason" ] || { echo "ALLOWLIST   entry for $afile has no reason"; bad=$((bad + 1)); }
  if grep -qxF -- "$afile|$apath" "$WORK/untagged"; then n_allow=$((n_allow + 1)); else
    echo "ALLOWLIST   allowlist entry matches no untagged image: $afile: $apath — remove it and lower ALLOW_PINNED_TOTAL"; bad=$((bad + 1)); fi
done < "$WORK/allow"
while IFS= read -r u; do
  cut -d'|' -f1,2 "$WORK/allow" | grep -qxF -- "$u" || {
    echo "NOT PINNED  ${u%%|*}: ${u#*|} has a repository with no tag and no digest, and is not on the allowlist"; bad=$((bad + 1)); }
done < "$WORK/untagged"

if [ "$bad" -ne 0 ]; then
  echo "FAIL: $bad finding(s) above. Read from $nrefs \`image\` references in $nfiles YAML files under $SCAN/."
  exit 1
fi
echo "ok: $nrefs \`image\` references read from $nfiles YAML files under $SCAN/ — $n_str string and $n_map {repository, tag} references end in @sha256:<64 hex>; $n_allow have no tag in the manifest and are the $ALLOW_PINNED_TOTAL allowlisted ones."
echo "    Not covered: chart-default images with no \`image\` key here, images under other key names, OCIRepository chart tags."
