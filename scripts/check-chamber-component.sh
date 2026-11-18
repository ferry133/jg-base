#!/usr/bin/env bash
# The im/chamber component (ferry133/jg-base#248, openspec im-chamber-identity)
# adds im's chamber identity to an im pod. Two things have to hold, and nothing
# else ties them together:
#
#   A. A cluster that has not turned it on is untouched, and a cluster that has
#      gets the additions and nothing else.
#        1. no Kustomization in this repo references the component (so a merge
#           changes no pod);
#        2. on im/enabled AND on im/netdev: the render with the component,
#           minus its additions, IS the render without it;
#        3. the bridge runs the app container's image, pin included;
#        4. the bridge has a command (without one it runs ttyd).
#
#   B. The login credential stays out of the agent's reach. `app` is a root
#      shell an agent types into; the split into a bridge that holds the
#      credential and a client that does not is only real if the pod spec
#      keeps it so.
#        5. Secret im-chamber is referenced by the bridge container only --
#           no other container (init containers included) mounts it or reads
#           a key of it through env;
#        6. both references are `optional`: a pod whose Secret has not arrived
#           must still start, or chamber takes the terminal down with it;
#        7. the socket volume is an emptyDir mounted by exactly app and the
#           bridge, at one path, and app's CHAMBER_URL is a path inside it;
#        8. the bridge declares no port and no probe (the pod is hostNetwork:
#           a port is the node's; a probe would make a bridge fault a pod fault).
#           ⚠️ "no probe" is a PROVISIONAL answer to an open question (design
#           Open Question 4: should a hung bridge be restarted by a liveness
#           probe?). If that is ruled the other way, this assertion narrows to
#           "no readiness probe" -- change it here with the ruling, do not
#           work around it;
#        9. the signer list is mounted into app only, read-only, WITHOUT
#           subPath (a subPath mount never follows a ConfigMap update, and a
#           revocation only counts where the copy was refreshed), and the
#           ConfigMap carries exactly the two files.
#
# What this does NOT measure: anything on a running pod (that the credential
# is really absent from app's filesystem, that no TCP socket is opened) -- that
# is the sub-change's tasks 2.5, on a throwaway cluster. And `flux build` is
# the CLI's reading of spec.components, not the in-cluster controller's.
#
# Usage: scripts/check-chamber-component.sh [--self-test]
#   exit 0 held, 1 not, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-$ROOT/kubernetes/apps/base/claudecode/claude-code}"
KUBE_DIR="${KUBE_DIR:-$ROOT/kubernetes}"
command -v yq   >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }
command -v flux >/dev/null 2>&1 || { echo "cannot measure: the flux CLI is missing (CI installs it)"; exit 2; }

HR='select(.kind == "HelmRelease" and .metadata.name == "im")'
V="$HR | .spec.values"
SECRET=im-chamber
BRIDGE=chamber-bridge
ADDED_ENV="CHAMBER_URL CHAMBER_ACCOUNT CHAMBER_MODE CHAMBER_SIGNERS_DIR"
ADDED_VOLS="chamber-socket chamber-token chamber-signers"

render() {  # app-dir, position, ks-file -> stdout
  flux build kustomization claude-code-im --dry-run \
    --path "$1/im/$2" --kustomization-file "$3" 2>&1
}

check() {
  local dir="$1" kube="$2" rc=0 work
  work="$(mktemp -d "${TMPDIR:-/tmp}/chamber-component.XXXXXX")" && [[ -d "$work" ]] \
    || { echo "cannot measure: could not create a scratch directory"; return 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  fail() { echo "FAIL — $1"; rc=1; }

  [[ -f "$dir/im/chamber/kustomization.yaml" ]] \
    || { echo "cannot measure: $dir/im/chamber/kustomization.yaml is not there"; return 2; }

  # 1. nothing turns it on. The subject is every YAML under kubernetes/ except
  #    the component's own directory. Comment lines are dropped first: the
  #    component's header shows the very line being looked for.
  local refs
  refs="$(grep -rnE --include='*.yaml' '^[[:space:]]*(-[[:space:]]+)?[^#]*im/chamber|^[[:space:]]*-[[:space:]]+\.\./chamber[[:space:]]*$' "$kube" 2>/dev/null \
            | grep -v "/im/chamber/" || true)"
  [[ -z "$refs" ]] || { fail "something references the chamber component — a merge would change an im pod:"; echo "$refs" | head -5 | sed 's/^/  /'; }

  # The Kustomization as shipped, plus the one line that turns the component on.
  yq '.spec.components = ["../chamber"]' "$dir/im-ks.yaml" > "$work/ks-on.yaml" \
    || { echo "cannot measure: could not derive a Kustomization with the component on"; return 2; }
  [[ "$(yq -r '.spec.components[0]' "$work/ks-on.yaml")" == "../chamber" ]] \
    || { echo "cannot measure: the derived Kustomization does not carry spec.components"; return 2; }

  local pos
  for pos in enabled netdev; do
    render "$dir" "$pos" "$dir/im-ks.yaml" > "$work/$pos.yaml" \
      || { echo "cannot measure: im/$pos itself does not build:"; sed 's/^/  /' "$work/$pos.yaml" | head -5; return 2; }
    # The reader's control: a field every im render has.
    [[ "$(yq -r "$HR | .spec.values.controllers.im.containers.talos-mcp.command[0]" "$work/$pos.yaml")" == "python3" ]] \
      || { echo "cannot measure: could not read talos-mcp's command from the im/$pos render — nothing read below would be a reading"; return 2; }
    if ! render "$dir" "$pos" "$work/ks-on.yaml" > "$work/$pos-on.yaml"; then
      fail "im/$pos with the component does not build (without it, it does):"; sed 's/^/  /' "$work/$pos-on.yaml" | head -5
      continue
    fi
    [[ "$(yq -r "$HR | .spec.values.controllers.im.containers | has(\"$BRIDGE\")" "$work/$pos-on.yaml")" == "true" ]] \
      || { fail "im/$pos with the component has no $BRIDGE container — the component was not applied, so nothing below is about it"; continue; }

    # 2. minus the additions, it is the render without the component.
    local strip="del(.controllers.im.containers.$BRIDGE)" x
    for x in $ADDED_ENV;  do strip="$strip | del(.controllers.im.containers.app.env.$x)"; done
    for x in $ADDED_VOLS; do strip="$strip | del(.persistence.$x)"; done
    yq -o json -P 'sort_keys(..)' "$work/$pos.yaml" > "$work/$pos.json"
    yq -o json -P "select(.kind != \"ConfigMap\" or .metadata.name != \"im-chamber-signers\") | ($HR | .spec.values) |= ($strip) | sort_keys(..)" \
      "$work/$pos-on.yaml" > "$work/$pos-minus.json"
    if ! diff -q "$work/$pos.json" "$work/$pos-minus.json" >/dev/null; then
      fail "on im/$pos the component changes more than it adds — with its additions removed the render still differs:"
      diff "$work/$pos.json" "$work/$pos-minus.json" | head -12 | sed 's/^/  /'
    fi

    # Every reading below is taken from the im HelmRelease's values ALONE, in a
    # file of their own. The render is a multi-document stream, and an
    # expression that builds an array (`[...] | any`) answers once per
    # document: three documents gave "false false false", which is not
    # "false", and four assertions went red on a correct component.
    local full="$work/$pos-on.yaml" f="$work/$pos-on-values.yaml" V="."
    yq "$HR | .spec.values" "$full" > "$f"
    [[ "$(yq -r '.controllers.im.containers.talos-mcp.command[0]' "$f")" == "python3" && "$(yq -r 'document_index' "$f" | wc -l | tr -d ' ')" == "1" ]] \
      || { echo "cannot measure: could not isolate the im HelmRelease's values from the im/$pos render with the component"; return 2; }
    local C=".controllers.im.containers" B=".controllers.im.containers.$BRIDGE"

    # 3. one build.
    local brepo btag arepo atag
    brepo="$(yq -r "$V | $B.image.repository" "$f")"; btag="$(yq -r "$V | $B.image.tag" "$f")"
    arepo="$(yq -r "$V | $C.app.image.repository" "$f")"; atag="$(yq -r "$V | $C.app.image.tag" "$f")"
    [[ "$btag" != "null" && -n "$btag" && "$brepo" == "$arepo" && "$btag" == "$atag" ]] \
      || fail "im/$pos: $BRIDGE image ${brepo}:${btag} is not the app container's ${arepo}:${atag}"

    # 4. a command.
    [[ "$(yq -o json -I0 "$V | $B.command" "$f")" == '["chamber-bridge"]' ]] \
      || fail "im/$pos: $BRIDGE command is $(yq -o json -I0 "$V | $B.command" "$f") — without the bridge's own command the container runs the image entrypoint (ttyd)"

    # 5. who can see the Secret. Every container and init container's env, and
    #    every persistence entry backed by the Secret.
    local envusers volusers
    envusers="$(yq -r "$V | .controllers.im | ((.containers // {}) * (.initContainers // {})) | to_entries | .[] | select(.value.env // {} | to_entries | any_c(.value.valueFrom.secretKeyRef.name == \"$SECRET\")) | .key" "$f" | sort | tr '\n' ' ')"
    local envfrom
    envfrom="$(yq -r "$V | .controllers.im | ((.containers // {}) * (.initContainers // {})) | to_entries | .[] | select([.value.envFrom[]?.secretRef.name, .value.envFrom[]?.secret] | any_c(. == \"$SECRET\")) | .key" "$f" | sort | tr '\n' ' ')"
    [[ -z "$envfrom" ]] || fail "im/$pos: containers taking Secret $SECRET whole through envFrom: [${envfrom% }] — every key, the token included, becomes an environment variable"
    [[ "$envusers" == "$BRIDGE " ]] \
      || fail "im/$pos: containers reading Secret $SECRET through env are [${envusers% }], not exactly [$BRIDGE]"
    local SV="(.volumeSpec.secret.secretName == \"$SECRET\") or (.type == \"secret\" and .name == \"$SECRET\") or ([.volumeSpec.projected.sources[]?.secret.name] | any_c(. == \"$SECRET\"))"
    volusers="$(yq -r "$V | [.persistence[] | select($SV)] | .[] | (.advancedMounts.im // {}) | keys | .[]" "$f" | sort -u | tr '\n' ' ')"
    # A Secret-backed volume with globalMounts, or with no advancedMounts at
    # all, is mounted into EVERY container. Counted on its own: an expression
    # that mixed the two readings printed the marker unconditionally.
    local volglobal
    volglobal="$(yq -r "$V | [.persistence[] | select($SV)] | map(select(has(\"globalMounts\") or (has(\"advancedMounts\") | not))) | length" "$f")"
    [[ "$volglobal" == "0" ]] || volusers="${volusers}<every container> "
    [[ "$volusers" == "$BRIDGE " ]] \
      || fail "im/$pos: containers mounting Secret $SECRET are [${volusers% }], not exactly [$BRIDGE]"

    # 6. optional, both ways in.
    [[ "$(yq -r "$V | $B.env.CHAMBER_URL.valueFrom.secretKeyRef.optional" "$f")" == "true" ]] \
      || fail "im/$pos: the bridge's CHAMBER_URL secretKeyRef is not optional — a pod whose Secret has not arrived would not start"
    [[ "$(yq -r "$V | .persistence.chamber-token.volumeSpec.secret.optional" "$f")" == "true" ]] \
      || fail "im/$pos: the chamber-token volume is not optional — a pod whose Secret has not arrived would sit in ContainerCreating, terminal included"
    local tokfile tokmount
    tokfile="$(yq -r "$V | $B.env.CHAMBER_TOKEN_FILE // \"\"" "$f")"
    tokmount="$(yq -r "$V | .persistence.chamber-token.advancedMounts.im.$BRIDGE[0].path // \"\"" "$f")"
    case "$tokfile" in "$tokmount"/?*) [[ -n "$tokmount" ]] || fail "im/$pos: the bridge does not mount chamber-token" ;;
      *) fail "im/$pos: CHAMBER_TOKEN_FILE=${tokfile:-unset} is not inside the chamber-token mount ${tokmount:-<none>}" ;; esac

    # 7. the socket.
    local sockusers sockpaths url
    [[ "$(yq -r "$V | .persistence.chamber-socket.type" "$f")" == "emptyDir" ]] \
      || fail "im/$pos: chamber-socket is not an emptyDir"
    [[ "$(yq -r "$V | .persistence.chamber-socket | has(\"globalMounts\")" "$f")" == "false" ]] \
      || fail "im/$pos: chamber-socket has globalMounts — every container would see the socket"
    sockusers="$(yq -r "$V | .persistence.chamber-socket.advancedMounts.im | keys | .[]" "$f" | sort | tr '\n' ' ')"
    [[ "$sockusers" == "app $BRIDGE " ]] \
      || fail "im/$pos: the socket volume is mounted by [${sockusers% }], not exactly [app $BRIDGE]"
    sockpaths="$(yq -r "$V | .persistence.chamber-socket.advancedMounts.im | .[] | .[].path" "$f" | sort -u | tr '\n' ' ')"
    url="$(yq -r "$V | $C.app.env.CHAMBER_URL" "$f")"
    case "$sockpaths" in *" "*" ") fail "im/$pos: the socket volume is mounted at more than one path: ${sockpaths% }" ;; esac
    case "$url" in "unix:${sockpaths% }"/?*) : ;; *) fail "im/$pos: app CHAMBER_URL=${url} is not unix:<a path inside ${sockpaths% }>" ;; esac
    [[ "$(yq -r "$V | $B.env.CHAMBER_SOCKET // \"\"" "$f")" == "${url#unix:}" ]] \
      || fail "im/$pos: the bridge listens at $(yq -r "$V | $B.env.CHAMBER_SOCKET // \"unset\"" "$f") and app dials ${url#unix:}"

    # 8. no port, no probe.
    [[ "$(yq -r "$V | $B | [has(\"ports\"), has(\"probes\")] | any" "$f")" == "false" ]] \
      || fail "im/$pos: $BRIDGE declares ports or probes"
    [[ "$(yq -r "$V | [(.service // {}) | .. | select(tag == \"!!str\")] | any_c(. == \"$BRIDGE\")" "$f")" == "false" ]] \
      || fail "im/$pos: a Service names $BRIDGE"

    # 9. the signer list.
    local sgusers sgsub sgro keys
    sgusers="$(yq -r "$V | .persistence.chamber-signers.advancedMounts.im | keys | .[]" "$f" | sort | tr '\n' ' ')"
    [[ "$sgusers" == "app " && "$(yq -r "$V | .persistence.chamber-signers | has(\"globalMounts\")" "$f")" == "false" ]] \
      || fail "im/$pos: the signer list is mounted by [${sgusers% }] (or globally), not exactly [app]"
    sgsub="$(yq -r "$V | [.persistence.chamber-signers.advancedMounts.im.app[] | has(\"subPath\")] | any" "$f")"
    [[ "$sgsub" == "false" ]] || fail "im/$pos: the signer list is mounted with subPath — it would never follow a revocation"
    sgro="$(yq -r "$V | [.persistence.chamber-signers.advancedMounts.im.app[] | .readOnly == true] | all" "$f")"
    [[ "$sgro" == "true" ]] || fail "im/$pos: the signer list mount is not read-only"
    [[ "$(yq -r "$V | $C.app.env.CHAMBER_SIGNERS_DIR" "$f")" == "$(yq -r "$V | .persistence.chamber-signers.advancedMounts.im.app[0].path" "$f")" ]] \
      || fail "im/$pos: CHAMBER_SIGNERS_DIR is not the signer list's mount path"
    keys="$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "im-chamber-signers") | .data | keys | .[]' "$full" | sort | tr '\n' ' ')"
    [[ "$keys" == "allowed_signers revoked_signers " ]] \
      || fail "im/$pos: ConfigMap im-chamber-signers carries [${keys% }], not exactly [allowed_signers revoked_signers]"
    [[ "$(yq -r "$V | .persistence.chamber-signers.name" "$f")" == "im-chamber-signers" ]] \
      || fail "im/$pos: the signer volume does not name ConfigMap im-chamber-signers (a hashed name would restart the pod on every change, and a wrong one mounts nothing)"
  done

  [[ $rc -eq 0 ]] && echo "ok — the chamber component is off by default, adds only itself on im/enabled and im/netdev, and keeps Secret $SECRET in $BRIDGE alone"
  return $rc
}

self_test() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chamber-component-selftest.XXXXXX")" && [[ -d "$tmp" ]] \
    || { echo "cannot measure: could not create a scratch directory for the self-test"; return 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  local failed=0 n=0
  expect() {  # label, want_rc, want-text-in-first-finding, file-under-app-dir, yq-expr (empty = none)
    local label="$1" want="$2" text="$3" file="$4" expr="$5" got out before="" after=""
    n=$((n + 1))
    rm -rf "$tmp/kube"; mkdir -p "$tmp/kube/apps/base/claudecode"
    if ! cp -R "$APP_DIR" "$tmp/kube/apps/base/claudecode/claude-code"; then
      echo "FAIL  ${label}: could not stage the scratch copy — harness, not guard"; failed=$((failed + 1)); return
    fi
    local app="$tmp/kube/apps/base/claudecode/claude-code"
    if [[ -n "$expr" ]]; then
      before="$(cksum < "$app/$file")"
      yq -i "$expr" "$app/$file" || { echo "FAIL  ${label}: the mutation did not apply — harness, not guard"; failed=$((failed + 1)); return; }
      after="$(cksum < "$app/$file")"
      [[ "$before" != "$after" ]] || { echo "FAIL  ${label}: the mutation changed nothing — harness, not guard"; failed=$((failed + 1)); return; }
    fi
    out="$(check "$app" "$tmp/kube")"; got=$?
    if [[ "$got" != "$want" ]]; then
      echo "FAIL  ${label}: rc=${got}, wanted ${want}"; echo "$out" | head -6 | sed 's/^/        /'; failed=$((failed + 1))
    elif [[ -n "$text" ]] && ! grep -qF -- "$text" <<<"$out"; then
      # Red for the wrong reason is not a pass.
      echo "FAIL  ${label}: rc=${got} as wanted, but no finding mentions '${text}'"; echo "$out" | head -6 | sed 's/^/        /'; failed=$((failed + 1))
    else
      echo "PASS  ${label} (rc=${got})"
      # What was changed and what went red for it -- so "the mutation applied"
      # and "it was caught for the stated reason" are both on the page, not
      # only a count.
      if [[ -n "$expr" ]]; then
        echo "        mutated ${file}: cksum ${before%% *} -> ${after%% *}"
        echo "$out" | grep -m1 -F -- "$text" | cut -c1-170 | sed 's/^/        caught:  /'
      fi
    fi
  }
  local P=im/chamber/bridge.yaml K=im/chamber/kustomization.yaml KS=im-ks.yaml
  local PV=".spec.values" PC=".spec.values.controllers.im.containers"
  expect "unmutated copy is green"                    0 ""                         "$P" ""
  expect "the default Kustomization turns it on"      1 "references the chamber"   "$KS" '.spec.components = ["../chamber"]'
  expect "the patch edits an existing app env"        1 "changes more than it adds" "$P" "$PC.app.env.HOME = \"/root\""
  expect "the patch adds an env the guard does not list" 1 "changes more than it adds" "$P" "$PC.app.env.SESSION_KEEP = \"1\""
  expect "a tag is written and the replacement dropped" 1 "is not the app container's" "$K" 'del(.replacements)'
  expect "the bridge has no command"                  1 "command is"               "$P" "del($PC.chamber-bridge.command)"
  expect "the token is also mounted into app"         1 "containers mounting Secret" "$P" "$PV.persistence.chamber-token.advancedMounts.im.app = [{\"path\": \"/etc/chamber\"}]"
  expect "the token volume is mounted globally"       1 "containers mounting Secret" "$P" "$PV.persistence.chamber-token.globalMounts = [{\"path\": \"/etc/chamber\"}]"
  expect "app reads a key of the Secret through env"  1 "through env"              "$P" "$PC.app.env.CHAMBER_TOKEN.valueFrom.secretKeyRef = {\"name\": \"im-chamber\", \"key\": \"token\"}"
  expect "a second Secret-backed volume for another container" 1 "containers mounting Secret" "$P" "$PV.persistence.spare = {\"type\": \"secret\", \"name\": \"im-chamber\", \"advancedMounts\": {\"im\": {\"talos-mcp\": [{\"path\": \"/x\"}]}}}"
  expect "the bridge takes the whole Secret through envFrom" 1 "through envFrom"     "$P" "$PC.chamber-bridge.envFrom = [{\"secretRef\": {\"name\": \"im-chamber\"}}]"
  expect "app takes the whole Secret through envFrom"  1 "through envFrom"          "$P" "$PC.app.envFrom = [{\"secretRef\": {\"name\": \"im-chamber\"}}]"
  expect "an init container reads a key through env"   1 "through env"              "$P" "$PV.controllers.im.initContainers.oauth2-emails.env.X.valueFrom.secretKeyRef = {\"name\": \"im-chamber\", \"key\": \"token\"}"
  expect "a projected volume carries the Secret into app" 1 "containers mounting Secret" "$P" "$PV.persistence.proj = {\"type\": \"custom\", \"volumeSpec\": {\"projected\": {\"sources\": [{\"secret\": {\"name\": \"im-chamber\"}}]}}, \"advancedMounts\": {\"im\": {\"app\": [{\"path\": \"/x\"}]}}}"
  expect "the token volume's optional line is deleted" 1 "ContainerCreating"        "$P" "del($PV.persistence.chamber-token.volumeSpec.secret.optional)"
  expect "the token volume is not optional"           1 "ContainerCreating"        "$P" "$PV.persistence.chamber-token.volumeSpec.secret.optional = false"
  expect "the url env is not optional"                1 "secretKeyRef is not optional" "$P" "del($PC.chamber-bridge.env.CHAMBER_URL.valueFrom.secretKeyRef.optional)"
  expect "CHAMBER_TOKEN_FILE points outside the mount" 1 "is not inside the chamber-token mount" "$P" "$PC.chamber-bridge.env.CHAMBER_TOKEN_FILE = \"/run/secrets/token\""
  expect "a third container mounts the socket"        1 "socket volume is mounted by" "$P" "$PV.persistence.chamber-socket.advancedMounts.im.talos-mcp = [{\"path\": \"/run/chamber\"}]"
  expect "the socket volume is mounted globally"      1 "every container would see" "$P" "$PV.persistence.chamber-socket.globalMounts = [{\"path\": \"/run/chamber\"}]"
  expect "app dials a path outside the socket volume" 1 "is not unix:"             "$P" "$PC.app.env.CHAMBER_URL = \"unix:/tmp/bridge.sock\""
  expect "app dials loopback"                         1 "is not unix:"             "$P" "$PC.app.env.CHAMBER_URL = \"http://127.0.0.1:8766\""
  expect "the bridge listens somewhere else"          1 "the bridge listens at"    "$P" "$PC.chamber-bridge.env.CHAMBER_SOCKET = \"/run/chamber/other.sock\""
  expect "the bridge declares a port"                 1 "declares ports or probes" "$P" "$PC.chamber-bridge.ports = [{\"containerPort\": 8766}]"
  expect "the bridge gets a readiness probe"          1 "declares ports or probes" "$P" "$PC.chamber-bridge.probes.readiness.enabled = true"
  expect "the signer list is mounted with subPath"    1 "subPath"                  "$P" "$PV.persistence.chamber-signers.advancedMounts.im.app[0].subPath = \"allowed_signers\""
  expect "the signer list is writable"                1 "not read-only"            "$P" "del($PV.persistence.chamber-signers.advancedMounts.im.app[0].readOnly)"
  expect "the signer list is also mounted into the bridge" 1 "signer list is mounted by" "$P" "$PV.persistence.chamber-signers.advancedMounts.im.chamber-bridge = [{\"path\": \"/etc/chamber/signers\", \"readOnly\": true}]"
  expect "the revoked list is dropped from the ConfigMap" 1 "carries ["            "$K" 'del(.configMapGenerator[0].files[1])'
  expect "the ConfigMap name gets a hash suffix"      1 "does not name ConfigMap"  "$P" "$PV.persistence.chamber-signers.name = \"im-chamber-signers-abc\""
  expect "the component does not build"               1 "does not build"           "$K" '.patches[0].path = "./nope.yaml"'
  expect "the reader is blind (talos-mcp command gone)" 2 "cannot measure"         "im/enabled/helmrelease.yaml" 'del(.spec.values.controllers.im.containers.talos-mcp.command)'

  if (( failed > 0 )); then
    echo "${failed} of ${n} self-test cases did not behave — the guard above cannot be trusted to go red"
    return 1
  fi
  echo "ok — ${n} self-test cases: green unmutated, red on every mutation for the stated reason, 2 when the reader is blind"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
else
  check "$APP_DIR" "$KUBE_DIR"
fi
