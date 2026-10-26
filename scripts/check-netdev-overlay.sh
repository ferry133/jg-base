#!/usr/bin/env bash
# Assert the im/netdev overlay (ferry133/jg-base#222) is im/enabled plus the
# netdev-mcp sidecar and NOTHING else, and that the sidecar is wired the way
# the k8scc contract needs.
#
# No Kustomization in this repo points at im/netdev -- jg-cluster-template
# switches claude-code-im to it per cluster -- so flux-local never builds it and
# check-envsubst-parses.sh never scans it. Without this script the overlay is
# a directory no CI job reads, which looks exactly like one that passes.
#
# It renders, rather than reading the source text, because the two facts that
# matter only exist after kustomize runs: the replacement that copies the app
# container's pinned tag into netdev-mcp (a stale second pin is the failure it
# prevents -- k8scc's bump PRs rewrite only im/enabled/helmrelease.yaml), and
# the merge of the patch into the base. The renderer is `flux build
# kustomization --dry-run`, Flux's own kustomize, which CI already installs for
# check-envsubst-parses.sh; no second toolchain.
#
# What is asserted, and the failure each one names:
#   1. ADDITIONS ONLY: the netdev render with the three additions deleted
#      (container netdev-mcp, volume unifi-reader, app env NETDEV_MCP_URL) is
#      equal to the im/enabled render. A patch that changes an existing key
#      would change the default terminal on every console cluster.
#   2. netdev-mcp runs the app container's image, repository and tag.
#   3. its command is the server, not the image entrypoint (which starts ttyd).
#   4. NETDEV_MCP_URL, the probe ports and NETDEV_MCP_PORT (if set) agree.
#      They sit in different containers; disagreeing, the app registers a dead
#      server or the probes kill a healthy one.
#   5. UNIFI_CA_FILE and UNIFI_READER_KEY_FILE point inside the unifi-reader
#      mount on netdev-mcp, which is readOnly and not subPath (rotation).
#   6. ONLY netdev-mcp mounts unifi-reader, no container env-reads Secret
#      unifi-reader, and the volume is optional (a missing Secret must not stop
#      the rescue terminal from starting).
#   7. NETDEV_ALLOW_INSECURE_HTTP appears nowhere: it is a test flag
#      (k8scc-c7, #222).
#   8. Flux's own envsubst parses the render (comments included, #123).
#
# --self-test mutates a scratch copy of the app directory once per assertion
# and requires RED on each, with the unmutated copy GREEN first.
#
# Usage: scripts/check-netdev-overlay.sh [--self-test]
#   exit 0 held, 1 not, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-$ROOT/kubernetes/apps/base/claudecode/claude-code}"
command -v yq   >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }
command -v flux >/dev/null 2>&1 || { echo "cannot measure: the flux CLI is missing (CI installs it)"; exit 2; }

V='select(.kind == "HelmRelease" and .metadata.name == "im") | .spec.values'

render() {  # app-dir, position -> stdout
  flux build kustomization claude-code-im --dry-run \
    --path "$1/im/$2" --kustomization-file "$1/im-ks.yaml" 2>&1
}

check() {
  local dir="$1" rc=0 work
  work="$(mktemp -d "${TMPDIR:-/tmp}/netdev-overlay.XXXXXX")" && [[ -d "$work" ]] \
    || { echo "cannot measure: could not create a scratch directory"; return 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  fail() { echo "FAIL — $1"; rc=1; }

  render "$dir" enabled > "$work/en.yaml" \
    || { echo "cannot measure: im/enabled itself does not build:"; sed 's/^/  /' "$work/en.yaml"; return 2; }
  # The reader's control: a field that exists in every im render. If it reads
  # back empty, every absence below would be the reader's, not the overlay's.
  [[ "$(yq -r "$V | .controllers.im.containers.talos-mcp.command[0]" "$work/en.yaml")" == "python3" ]] \
    || { echo "cannot measure: could not read talos-mcp's command from the im/enabled render, so nothing read from the overlay's would be a reading"; return 2; }
  if ! render "$dir" netdev > "$work/nd.yaml"; then
    echo "FAIL — im/netdev does not build (im/enabled does):"; sed 's/^/  /' "$work/nd.yaml"; return 1
  fi

  local C=".controllers.im.containers" N=".controllers.im.containers.netdev-mcp"

  # ---- 1. additions only
  yq -o json -P 'sort_keys(..)' "$work/en.yaml" > "$work/en.json"
  yq -o json -P "(select(.kind == \"HelmRelease\" and .metadata.name == \"im\") | .spec.values) |= (del($N) | del(.persistence.unifi-reader) | del($C.app.env.NETDEV_MCP_URL)) | sort_keys(..)" "$work/nd.yaml" > "$work/nd-minus.json"
  if ! diff -q "$work/en.json" "$work/nd-minus.json" >/dev/null; then
    fail "the overlay changes more than it adds — with netdev-mcp, unifi-reader and NETDEV_MCP_URL removed, the render still differs from im/enabled:"
    diff "$work/en.json" "$work/nd-minus.json" | head -20 | sed 's/^/  /'
  fi

  # ---- 2. image
  local nrepo ntag arepo atag
  nrepo="$(yq -r "$V | $N.image.repository" "$work/nd.yaml")"; ntag="$(yq -r "$V | $N.image.tag" "$work/nd.yaml")"
  arepo="$(yq -r "$V | $C.app.image.repository" "$work/nd.yaml")"; atag="$(yq -r "$V | $C.app.image.tag" "$work/nd.yaml")"
  [[ "$ntag" != "null" && -n "$ntag" && "$nrepo" == "$arepo" && "$ntag" == "$atag" ]] \
    || fail "netdev-mcp image ${nrepo}:${ntag} is not the app container's ${arepo}:${atag} — the replacement in im/netdev/kustomization.yaml is what keeps them one build"

  # ---- 3. command
  local cmd
  cmd="$(yq -o json -I0 "$V | $N.command" "$work/nd.yaml")"
  [[ "$cmd" == '["python3","/usr/local/bin/netdev_mcp_server.py"]' ]] \
    || fail "netdev-mcp command is ${cmd}, not the server — without it the container runs the image entrypoint (ttyd)"

  # ---- 4. one port
  local url port lp rp ep
  url="$(yq -r "$V | $C.app.env.NETDEV_MCP_URL" "$work/nd.yaml")"
  port="$(printf '%s' "$url" | sed -n 's#^http://127\.0\.0\.1:\([0-9][0-9]*\)/sse$#\1#p')"
  lp="$(yq -r "$V | $N.probes.liveness.spec.exec.command[2]" "$work/nd.yaml" | sed -n 's#.*/dev/tcp/127\.0\.0\.1/\([0-9][0-9]*\)$#\1#p')"
  rp="$(yq -r "$V | $N.probes.readiness.spec.exec.command[2]" "$work/nd.yaml" | sed -n 's#.*/dev/tcp/127\.0\.0\.1/\([0-9][0-9]*\)$#\1#p')"
  ep="$(yq -r "$V | $N.env.NETDEV_MCP_PORT // \"\"" "$work/nd.yaml")"
  if [[ -z "$port" ]]; then
    fail "app NETDEV_MCP_URL is '${url}', not http://127.0.0.1:<port>/sse — the sidecar binds loopback on a hostNetwork pod"
  else
    [[ "$lp" == "$port" && "$rp" == "$port" ]] \
      || fail "NETDEV_MCP_URL says port ${port}, the probes dial liveness '${lp}' / readiness '${rp}'"
    [[ -z "$ep" || "$ep" == "$port" ]] \
      || fail "netdev-mcp NETDEV_MCP_PORT=${ep} but the app registers port ${port}"
  fi

  # ---- 5. paths inside the mount
  local mpath mro msub ca key
  mpath="$(yq -r "$V | .persistence.unifi-reader.advancedMounts.im.netdev-mcp[0].path" "$work/nd.yaml")"
  mro="$(yq -r "$V | .persistence.unifi-reader.advancedMounts.im.netdev-mcp[0].readOnly" "$work/nd.yaml")"
  msub="$(yq -r "$V | .persistence.unifi-reader.advancedMounts.im.netdev-mcp[0].subPath // \"\"" "$work/nd.yaml")"
  ca="$(yq -r "$V | $N.env.UNIFI_CA_FILE" "$work/nd.yaml")"
  key="$(yq -r "$V | $N.env.UNIFI_READER_KEY_FILE" "$work/nd.yaml")"
  if [[ "$mpath" == "null" || -z "$mpath" ]]; then
    fail "netdev-mcp does not mount unifi-reader — the server would read no CA and no key"
  else
    case "$ca"  in "$mpath"/?*) : ;; *) fail "UNIFI_CA_FILE=${ca} is not inside the unifi-reader mount ${mpath}" ;; esac
    case "$key" in "$mpath"/?*) : ;; *) fail "UNIFI_READER_KEY_FILE=${key} is not inside the unifi-reader mount ${mpath}" ;; esac
    [[ "$mro" == "true" ]] || fail "the unifi-reader mount is not readOnly"
    [[ -z "$msub" ]] || fail "the unifi-reader mount uses subPath ${msub} — a subPath mount never sees a rotated key"
  fi

  # ---- 6. isolation
  local mounters global opt readers
  mounters="$(yq -r "$V | .persistence.unifi-reader.advancedMounts.im // {} | keys | join(\" \")" "$work/nd.yaml")"
  global="$(yq -r "$V | .persistence.unifi-reader.globalMounts // [] | length" "$work/nd.yaml")"
  [[ "$mounters" == "netdev-mcp" && "$global" == "0" ]] \
    || fail "unifi-reader is mounted by '${mounters}' (globalMounts: ${global}), not by netdev-mcp alone — the app container is the customer's root shell"
  opt="$(yq -r "$V | .persistence.unifi-reader.volumeSpec.secret.optional" "$work/nd.yaml")"
  [[ "$opt" == "true" ]] \
    || fail "the unifi-reader volume is not optional — a Secret that has not landed yet would keep the rescue terminal from starting"
  readers="$(yq -r "$V | .controllers.im | ((.containers // {}) + (.initContainers // {})) | to_entries[] | select(([.value.env // {} | .[] | select(type == \"!!map\") | (.valueFrom.secretKeyRef.name // \"\")] | map(select(. == \"unifi-reader\")) | length) > 0) | .key" "$work/nd.yaml" | tr '\n' ' ')"
  [[ -z "$readers" ]] \
    || fail "containers env-read Secret unifi-reader: ${readers}— the credential belongs in the netdev-mcp mount only"

  # ---- 7. no insecure flag
  local insecure
  insecure="$(yq -r "$V | .controllers.im | ((.containers // {}) + (.initContainers // {})) | to_entries[] | select(.value.env.NETDEV_ALLOW_INSECURE_HTTP != null) | .key" "$work/nd.yaml" | tr '\n' ' ')"
  [[ -z "$insecure" ]] \
    || fail "NETDEV_ALLOW_INSECURE_HTTP is set on: ${insecure}— a test-only flag that lets the reader key cross the LAN in clear"

  # ---- 8. Flux substitution parses
  local es
  if ! es="$(flux envsubst < "$work/nd.yaml" 2>&1 >/dev/null)"; then
    fail "Flux's envsubst rejects the im/netdev render (comments are scanned too, #123): ${es}"
  fi

  if [[ $rc -eq 0 ]]; then
    echo "PASS — im/netdev = im/enabled + netdev-mcp + unifi-reader + NETDEV_MCP_URL, nothing else changed"
    echo "       netdev-mcp image = app image (${ntag%%@*}); command = server; port ${port} in URL and both probes"
    echo "       CA ${ca} and key ${key} inside ${mpath} (readOnly, no subPath, optional);"
    echo "       mounted by netdev-mcp only, env-read by none; no insecure flag; envsubst parses"
  fi
  return $rc
}

self_test() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/netdev-overlay-self.XXXXXX")" && [[ -d "$tmp" ]] \
    || { echo "cannot measure: could not create a scratch directory for the self-test"; return 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  local failed=0 n=0
  expect() {  # label, want_rc, file-under-app-dir, yq-expr (empty = none)
    local label="$1" want="$2" file="$3" expr="$4" got out
    n=$((n + 1))
    rm -rf "$tmp/app"
    if ! cp -R "$APP_DIR" "$tmp/app"; then
      echo "FAIL  ${label}: could not stage the scratch copy — harness, not guard"; failed=$((failed + 1)); return
    fi
    if [[ -n "$expr" ]]; then
      local before after
      before="$(cksum < "$tmp/app/$file")"
      yq -i "$expr" "$tmp/app/$file" || { echo "FAIL  ${label}: the mutation did not apply — harness, not guard"; failed=$((failed + 1)); return; }
      after="$(cksum < "$tmp/app/$file")"
      [[ "$before" != "$after" ]] || { echo "FAIL  ${label}: the mutation changed nothing — harness, not guard"; failed=$((failed + 1)); return; }
    fi
    out="$(check "$tmp/app")"; got=$?
    if [[ "$got" == "$want" ]]; then
      echo "PASS  ${label} (rc=${got})"
      # The reason it went red, so a case caught by the WRONG assertion is
      # visible here and not only as a matching exit code.
      [[ "$want" == 0 ]] || echo "$out" | grep -m1 -E '^(FAIL|cannot measure)' | cut -c1-150 | sed 's/^/        /'
    else
      echo "FAIL  ${label}: rc=${got}, wanted ${want}"; echo "$out" | sed 's/^/        /'; failed=$((failed + 1))
    fi
  }
  local P=im/netdev/netdev-mcp.yaml K=im/netdev/kustomization.yaml E=im/enabled/helmrelease.yaml
  local PC='.spec.values.controllers.im.containers'
  expect "0. unmutated copy is green" 0 "" ""
  expect "1. patch changes an existing key (app LANG)" 1 "$P" "$PC.app.env.LANG = \"C\""
  expect "1b. patch drops oauth2-proxy's memory limit" 1 "$P" "$PC.oauth2-proxy.resources.limits.memory = \"64Mi\""
  expect "2. replacement gone (netdev-mcp has no tag)" 1 "$K" 'del(.replacements)'
  expect "2b. replacement copies the wrong field" 1 "$K" '.replacements[0].source.fieldPath = "spec.values.controllers.im.containers.oauth2-proxy.image.tag"'
  expect "3. command removed (entrypoint would run ttyd)" 1 "$P" "del($PC.netdev-mcp.command)"
  expect "4. app URL on talos-mcp's port" 1 "$P" "$PC.app.env.NETDEV_MCP_URL = \"http://127.0.0.1:8765/sse\""
  expect "4b. readiness probe on another port" 1 "$P" "$PC.netdev-mcp.probes.readiness.spec.exec.command[2] = \"exec 3<>/dev/tcp/127.0.0.1/8767\""
  expect "4c. NETDEV_MCP_PORT disagrees" 1 "$P" "$PC.netdev-mcp.env.NETDEV_MCP_PORT = \"8767\""
  expect "5. CA path outside the mount" 1 "$P" "$PC.netdev-mcp.env.UNIFI_CA_FILE = \"/etc/netdev-mcp/ca.crt\""
  expect "5b. mount via subPath" 1 "$P" '.spec.values.persistence.unifi-reader.advancedMounts.im.netdev-mcp[0].subPath = "reader-key"'
  expect "5c. mount not readOnly" 1 "$P" '.spec.values.persistence.unifi-reader.advancedMounts.im.netdev-mcp[0].readOnly = false'
  expect "6. app container mounts the reader too" 1 "$P" '.spec.values.persistence.unifi-reader.advancedMounts.im.app = [{"path": "/etc/netdev-mcp/reader", "readOnly": true}]'
  expect "6b. volume not optional" 1 "$P" '.spec.values.persistence.unifi-reader.volumeSpec.secret.optional = false'
  # 6c is caught by assertion 1 as well (it changes the app container); 6d is
  # the case only assertion 6 can see -- the sidecar itself taking the key
  # through env, where it shows in the process environment.
  expect "6c. app env-reads the Secret" 1 "$P" "$PC.app.env.UNIFI_KEY = {\"valueFrom\": {\"secretKeyRef\": {\"name\": \"unifi-reader\", \"key\": \"reader-key\"}}}"
  expect "6d. netdev-mcp env-reads the Secret" 1 "$P" "$PC.netdev-mcp.env.UNIFI_KEY = {\"valueFrom\": {\"secretKeyRef\": {\"name\": \"unifi-reader\", \"key\": \"reader-key\"}}}"
  expect "7. insecure-http flag set" 1 "$P" "$PC.netdev-mcp.env.NETDEV_ALLOW_INSECURE_HTTP = \"1\""
  expect "8. unparseable dollar-brace in a value" 1 "$P" "$PC.netdev-mcp.env.UNIFI_SITE = \"\${...}\""
  expect "r. reader control broken (talos-mcp command gone) → cannot measure, not pass" 2 "$E" 'del(.spec.values.controllers.im.containers.talos-mcp.command)'
  echo
  if [[ $failed -gt 0 ]]; then
    echo "${failed} of ${n} self-test cases did not behave — the guard above cannot be trusted to go red"
    return 1
  fi
  echo "ok — ${n} self-test cases: green unmutated, red on every mutation, 2 when the reader is blind"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
else
  check "$APP_DIR"
fi
