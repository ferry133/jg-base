#!/usr/bin/env bash
# Assert the os:operator credential is wired to the talos-mcp container only,
# at ONE path, read-only -- and that its Secret key is a `data:` substitution
# that renders EMPTY (not unresolved, not base64 text) on a cluster that never
# minted one.
#
# im-onsite-operator-tools (2026-10-13) adds a second Talos credential to the
# talos-mcp sidecar: an Omni break-glass talosconfig with a client cert AND key
# inside, role ceiling os:operator. insideman's isolation boundary -- "the
# credential is mounted only into the sidecar, never into the app container" --
# is what makes that acceptable, and it is held by three lines in two files
# that nothing else ties together:
#
#   talos-mcp-secret.yaml  data.operatorConfig: "${TALOS_OPERATOR_CONFIG_B64:-}"
#   helmrelease.yaml       talos-mcp env TALOS_OPERATOR_CONFIG: <path>
#   helmrelease.yaml       talos-mcp mount  - path: <path>  subPath: operatorConfig  readOnly: true
#
# What is asserted, and the failure each one names:
#   1. the key is under `data:` (a b64-wrapped value, decoded on mount) and is a
#      Flux substitution of TALOS_OPERATOR_CONFIG_B64. Under `stringData:` the
#      mounted file would be the base64 TEXT, and talosctl would reject it as a
#      corrupt config on every cluster -- including the ones that minted nothing.
#   2. the env path and the mount path are the SAME string. They sit sixty
#      lines apart; edit one and the server reads 0 bytes at its path (== absent,
#      by design) while the real credential sits unread at the other --
#      reboot_node silently gone, every signal green. This is the one a review
#      would not catch, and the reason this file exists.
#   3. the mount is subPath `operatorConfig` and readOnly.
#   4. ONLY talos-mcp mounts talos-mcp-config, and no other container (init
#      containers included) reads talos-mcp-secret through env. The app
#      container is a root shell the customer types into; a credential visible
#      there is the 2026-10-11 anti-pattern this change exists to end.
#   5. POD_IP on talos-mcp is the downward-API status.podIP: reboot_node uses it
#      to recognise its own node (and then not --wait, or the call never returns).
#
# Deliberately a text check, not a render: a guard that needs kustomize + helm
# would exit "cannot measure" on every CI run, which reads the same as passing.
# The render was measured once (helm template of the chart with these values,
# PR for root task 3.3) and the live half -- an empty key mounts as a 0-byte
# file -- on jcom 2026-10-13. What regresses is the source; that is what this
# reads.
#
# --self-test applies one mutation per assertion to a scratch copy and requires
# the guard to go RED on each, with the unmutated copy staying green first: a
# guard that has never been seen red may be reading nothing (the model is
# scripts/check-lan-dns-row.sh's case table).
#
# Usage: scripts/check-operator-credential-isolation.sh [--self-test]
#   exit 0 held, 1 not, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HR="${HR:-$ROOT/kubernetes/apps/base/claudecode/claude-code/im/enabled/helmrelease.yaml}"
SECRET="${SECRET:-$ROOT/kubernetes/apps/base/claudecode/claude-code/app/talos-mcp-secret.yaml}"
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }

SSEL='select(.kind == "Secret" and .metadata.name == "talos-mcp-secret")'
HSEL='select(.kind == "HelmRelease") | .spec.values'
MOUNTS='.persistence.talos-mcp-config.advancedMounts.im'
TMCP='.controllers.im.containers.talos-mcp'

check() {
  local hr="$1" secret="$2" rc=0
  [[ -r "$hr" && -r "$secret" ]] || { echo "cannot measure: $hr or $secret not readable"; return 2; }
  fail() { echo "FAIL — $1"; rc=1; }

  # ---- 1. the Secret key
  local in_data in_str reader
  reader="$(yq -r "$SSEL | .data.talosconfig" "$secret")"
  [[ -n "$reader" && "$reader" != "null" ]] \
    || { echo "cannot measure: the reader could not see data.talosconfig either, so an absent operatorConfig would not be a reading"; return 2; }
  in_data="$(yq -r "$SSEL | .data.operatorConfig" "$secret")"
  in_str="$(yq -r "$SSEL | .stringData.operatorConfig" "$secret")"
  if [[ -z "$in_data" || "$in_data" == "null" ]]; then
    if [[ -n "$in_str" && "$in_str" != "null" ]]; then
      fail "operatorConfig is under stringData:, not data: — the value is b64-wrapped (TALOS_OPERATOR_CONFIG_B64), so the mounted file would be base64 TEXT and talosctl would reject it as corrupt on every cluster"
    else
      fail "talos-mcp-secret has no data.operatorConfig — the subPath mount has no key to project, and a minted credential reaches nothing"
    fi
  else
    case "$in_data" in
      '${TALOS_OPERATOR_CONFIG_B64'*'}') : ;;
      *) fail "data.operatorConfig is the literal '${in_data}', not a Flux substitution of TALOS_OPERATOR_CONFIG_B64 — the value must come from cluster-secrets, rendered by jg-cluster-template from talos_operator_config" ;;
    esac
  fi

  # ---- 2./3. env path == mount path, subPath operatorConfig, readOnly
  local env_path n_mnt mnt_path mnt_ro
  reader="$(yq -r "$HSEL | $TMCP.env.TALOSCONFIG" "$hr")"
  [[ -n "$reader" && "$reader" != "null" ]] \
    || { echo "cannot measure: the reader could not see talos-mcp's TALOSCONFIG either, so a missing TALOS_OPERATOR_CONFIG would not be a reading"; return 2; }
  env_path="$(yq -r "$HSEL | $TMCP.env.TALOS_OPERATOR_CONFIG" "$hr")"
  [[ -n "$env_path" && "$env_path" != "null" ]] \
    || fail "talos-mcp has no TALOS_OPERATOR_CONFIG env — the server never looks for the file, so a minted credential changes nothing"
  n_mnt="$(yq -r "$HSEL | [$MOUNTS.talos-mcp[] | select(.subPath == \"operatorConfig\")] | length" "$hr")"
  if [[ "$n_mnt" != "1" ]]; then
    fail "expected exactly one talos-mcp mount with subPath operatorConfig, found ${n_mnt} — the key in talos-mcp-secret is projected nowhere (or twice)"
  else
    mnt_path="$(yq -r "$HSEL | $MOUNTS.talos-mcp[] | select(.subPath == \"operatorConfig\") | .path" "$hr")"
    mnt_ro="$(yq -r "$HSEL | $MOUNTS.talos-mcp[] | select(.subPath == \"operatorConfig\") | .readOnly" "$hr")"
    [[ "$mnt_path" == "$env_path" ]] \
      || fail "TALOS_OPERATOR_CONFIG names '${env_path}' but the operatorConfig mount is at '${mnt_path}' — the server reads 0 bytes at its path (== absent, by design) while the real credential sits unread at the other: reboot_node silently gone, every signal green"
    [[ "$mnt_ro" == "true" ]] \
      || fail "the operatorConfig mount is not readOnly (read back '${mnt_ro}') — the credential file must not be writable from inside the pod"
  fi

  # ---- 4. isolation: only talos-mcp mounts it, nothing else env-reads the Secret
  local mounters readers
  mounters="$(yq -r "$HSEL | $MOUNTS | keys | .[]" "$hr" | sort | tr '\n' ' ')"
  [[ "$mounters" == "talos-mcp " ]] \
    || fail "talos-mcp-config is mounted into: ${mounters}— only talos-mcp may hold a Talos credential; the app container is the customer's root shell"
  readers="$(yq -r "$HSEL | .controllers.im | ((.containers // {}) + (.initContainers // {})) | to_entries[] | select(.key != \"talos-mcp\") | select(([.value.env // {} | .[] | select(type == \"!!map\") | (.valueFrom.secretKeyRef.name // \"\")] | map(select(. == \"talos-mcp-secret\")) | length) > 0) | .key" "$hr" | tr '\n' ' ')"
  [[ -z "$readers" ]] \
    || fail "containers other than talos-mcp read talos-mcp-secret through env: ${readers}— that is the credential crossing into the shell"

  # ---- 5. POD_IP
  local podip
  podip="$(yq -r "$HSEL | $TMCP.env.POD_IP.valueFrom.fieldRef.fieldPath" "$hr")"
  [[ "$podip" == "status.podIP" ]] \
    || fail "talos-mcp POD_IP is not the downward-API status.podIP (read back '${podip}') — reboot_node could not recognise its own node and would --wait on a reboot that takes it down"

  if [[ $rc -eq 0 ]]; then
    echo "PASS — data.operatorConfig = ${in_data}; talos-mcp env TALOS_OPERATOR_CONFIG = ${env_path} == mount path"
    echo "       (subPath operatorConfig, readOnly); talos-mcp-config mounted by: ${mounters}and no other container"
    echo "       env-reads talos-mcp-secret; POD_IP = ${podip}"
    echo "       (reader controls: data.talosconfig and env TALOSCONFIG both read back)"
  fi
  return $rc
}

self_test() {
  # The harness is gated BEFORE the cases, and loudly: on the first CI run
  # `mktemp -d -t name` (a BSD spelling; GNU wants XXXXXX) returned nothing,
  # every case ran against /hr.yaml and came back 2 -- and the one case that
  # EXPECTS 2 read as PASS. A case whose expected value is the harness's own
  # failure code is not a control once the harness is broken; so the harness
  # has to be shown working first, and a copy that fails to stage is a FAIL of
  # its own, never a case result.
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/operator-isolation.XXXXXX")" && [[ -d "$tmp" ]] \
    || { echo "cannot measure: could not create a scratch directory for the self-test"; return 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  local failed=0 n=0
  expect() {  # label, want_rc, yq-expr-for-HR, yq-expr-for-Secret
    local label="$1" want="$2" hexpr="$3" sexpr="$4" got out
    n=$((n + 1))
    if ! cp "$HR" "$tmp/hr.yaml" || ! cp "$SECRET" "$tmp/secret.yaml"; then
      echo "FAIL  ${label}: could not stage the scratch copy — harness, not guard"; failed=$((failed + 1)); return
    fi
    [[ -z "$hexpr" ]] || yq -i "$hexpr" "$tmp/hr.yaml"
    [[ -z "$sexpr" ]] || yq -i "$sexpr" "$tmp/secret.yaml"
    out="$(check "$tmp/hr.yaml" "$tmp/secret.yaml")"; got=$?
    if [[ "$got" == "$want" ]]; then
      echo "PASS  ${label} (rc=${got})"
    else
      echo "FAIL  ${label}: rc=${got}, wanted ${want}"; echo "$out" | sed 's/^/        /'; failed=$((failed + 1))
    fi
  }
  local OP='(.spec.values.persistence.talos-mcp-config.advancedMounts.im.talos-mcp[] | select(.subPath == "operatorConfig"))'
  expect "0. unmutated copy is green" 0 "" ""
  expect "1a. key deleted from the Secret" 1 "" 'del(.data.operatorConfig)'
  expect "1b. key moved to stringData" 1 "" 'del(.data.operatorConfig) | .stringData.operatorConfig = "${TALOS_OPERATOR_CONFIG_B64:-}"'
  expect "1c. key is a literal, not a substitution" 1 "" '.data.operatorConfig = "Y29udGV4dDogeA=="'
  expect "2a. env path changed (paths diverge)" 1 '.spec.values.controllers.im.containers.talos-mcp.env.TALOS_OPERATOR_CONFIG = "/etc/talos-mcp/operator"' ""
  expect "2b. env deleted" 1 'del(.spec.values.controllers.im.containers.talos-mcp.env.TALOS_OPERATOR_CONFIG)' ""
  expect "3a. mount subPath points at the reader key" 1 "$OP.subPath = \"talosconfig\"" ""
  expect "3b. mount loses readOnly" 1 "$OP.readOnly = false" ""
  expect "4a. app container mounts it too" 1 '.spec.values.persistence.talos-mcp-config.advancedMounts.im.app = [{"path": "/etc/talos-mcp/operator-talosconfig", "subPath": "operatorConfig", "readOnly": true}]' ""
  expect "4b. app container env-reads the Secret" 1 '.spec.values.controllers.im.containers.app.env.OPERATOR = {"valueFrom": {"secretKeyRef": {"name": "talos-mcp-secret", "key": "operatorConfig"}}}' ""
  expect "4c. init container env-reads the Secret" 1 '.spec.values.controllers.im.initContainers.oauth2-emails.env.OPERATOR = {"valueFrom": {"secretKeyRef": {"name": "talos-mcp-secret", "key": "operatorConfig"}}}' ""
  expect "5. POD_IP deleted" 1 'del(.spec.values.controllers.im.containers.talos-mcp.env.POD_IP)' ""
  expect "r. reader control broken (TALOSCONFIG gone) → cannot measure, not pass" 2 'del(.spec.values.controllers.im.containers.talos-mcp.env.TALOSCONFIG)' ""
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
  check "$HR" "$SECRET"
fi
