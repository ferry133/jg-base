#!/usr/bin/env bash
# Assert daily-check row 32 (App state on NFS, ferry133/jg-base#239) gives
# every verdict it claims. The cases run the real block from the ConfigMap.
#
# The kubectl stub answers ONLY the two reads the row makes: StorageClasses
# and PVCs cluster-wide. Anything else fails loudly. A stub that ignores its
# arguments is a constant, not a test double.
#
# Case 0 is the no-mutation control. Run against a fixture with no violation,
# it must come out green. If the instrument is broken, every case reads red,
# and that is indistinguishable from "every mutation was caught".
#
# The allowlist cases run on COPIES of the block with the array rewritten.
# The pin assertion at the bottom runs on the live block. That pin assertion is
# what acceptance 3 asks for: an entry added without moving
# NFS_ALLOW_PINNED makes CI fail.
#
# Usage: scripts/check-nfs-app-state-row.sh
#   exit 0 every case matches, 1 a case failed, 2 cannot measure here
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="$ROOT/kubernetes/apps/base/monitoring/daily-check"
CM="$DC/app/configmap.yaml"
[[ -r "$CM" ]] || { echo "cannot measure: daily-check ConfigMap not readable"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "cannot measure: jq is missing"; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nfs-row.XXXXXX")" || { echo "cannot measure: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT

BLOCK="$(awk '
    /^[[:space:]]*# 32\. Application state on an NFS class/ { grabbing = 1 }
    grabbing && /^[[:space:]]*# [0-9]+[a-z]?\. / && !/# 32\./ { exit }
    grabbing && /^[[:space:]]*if \[\[ \$FAIL_COUNT -gt 0 \]\]; then/ { exit }
    grabbing { print }
  ' "$CM" | sed 's/^    //')"
[[ -n "$BLOCK" ]] || { echo "cannot measure: row 32 was not found in the ConfigMap"; exit 2; }
grep -q 'NFS_NAME="App state on NFS"' <<<"$BLOCK" || { echo "cannot measure: extracted block is not row 32"; exit 2; }
bash -n <<<"$BLOCK" || { echo "cannot measure: extracted block does not parse"; exit 2; }
KGET="$(awk '/^    kget\(\) \{/ { g = 1 } g { print } g && /^    kget_items\(\) \{/ { k = 1 } k && /^    \}/ { exit }' "$CM" | sed 's/^    //')"
grep -q 'kget_items()' <<<"$KGET" || { echo "cannot measure: kget/kget_items were not found in the ConfigMap"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

# --- Static: the live block's allowlist matches its pin, and every entry has a reason.
LIVE_N="$(bash -c "$(sed -n '/^NFS_ALLOW=(/,/^)/p' <<<"$BLOCK"); echo \${#NFS_ALLOW[@]}")"
LIVE_PIN="$(sed -n 's/^NFS_ALLOW_PINNED=\([0-9][0-9]*\)$/\1/p' <<<"$BLOCK")"
if [[ -z "$LIVE_N" || -z "$LIVE_PIN" ]]; then
  echo "cannot measure: could not read the allowlist or its pin from row 32"; exit 2
elif [[ "$LIVE_N" != "$LIVE_PIN" ]]; then
  fail "row 32 allowlist has $LIVE_N entries but NFS_ALLOW_PINNED=$LIVE_PIN — move the pin deliberately, with a reason on the entry (#239)"
else
  echo "PASS  live allowlist: $LIVE_N entries, pinned at $LIVE_PIN"
fi
grep -q 'resources: \["storageclasses"\]' "$DC/app/rbac.yaml" \
  || fail "rbac.yaml does not grant storageclasses — the row would always warn"

SC_NFS='{"items":[{"metadata":{"name":"local-path"},"provisioner":"rancher.io/local-path"},{"metadata":{"name":"sc-nas"},"provisioner":"k8s-sigs.io/first-nfs-subdir-external-provisioner"}]}'
SC_NONE='{"items":[{"metadata":{"name":"local-path"},"provisioner":"rancher.io/local-path"},{"metadata":{"name":"longhorn"},"provisioner":"driver.longhorn.io"}]}'
SC_TWO='{"items":[{"metadata":{"name":"sc-nas"},"provisioner":"k8s-sigs.io/first-nfs-subdir-external-provisioner"},{"metadata":{"name":"nas-csi"},"provisioner":"nfs.csi.k8s.io"}]}'
pvc() {  # ns name class(- = no key, "" = static) phase
  if [[ "$3" == "-" ]]; then printf '{"metadata":{"namespace":"%s","name":"%s"},"spec":{},"status":{"phase":"%s"}}' "$1" "$2" "$4"
  else printf '{"metadata":{"namespace":"%s","name":"%s"},"spec":{"storageClassName":"%s"},"status":{"phase":"%s"}}' "$1" "$2" "$3" "$4"; fi
}
items() { local IFS=,; echo "{\"items\":[$*]}"; }

CLEAN="$(items "$(pvc db pg-data local-path Bound)" "$(pvc linebot showcase-vault '' Bound)" "$(pvc default unset - Pending)")"
ONE_BAD="$(items "$(pvc db pg-data local-path Bound)" "$(pvc default home-assistant-config sc-nas Bound)")"
TWO_BAD="$(items "$(pvc mqtt mosquitto-data sc-nas Bound)" "$(pvc media films nas-csi Pending)" "$(pvc linebot showcase-vault '' Bound)")"
BULK="$(items "$(pvc media films sc-nas Bound)" "$(pvc media music sc-nas Bound)")"

# with_allow <entries...> -- prints the block with the array and pin rewritten (pin = count unless PIN set)
with_allow() {
  local n=$# pin="${PIN:-$#}" body="" e
  for e in "$@"; do body+="  \"$e\""$'\n'; done
  BODY="$body" awk -v pin="$pin" '
    /^NFS_ALLOW=\($/ { print; printf "%s", ENVIRON["BODY"]; skip = 1; next }
    skip && /^\)$/ { skip = 0 }
    skip { next }
    /^NFS_ALLOW_PINNED=/ { print "NFS_ALLOW_PINNED=" pin; next }
    { print }' <<<"$BLOCK"
}

# case | block | sc json (- = refuse) | pvc json (- = refuse) | want level | texts (" && ")
run_case() {
  local name="$1" block="$2" sc="$3" pvcs="$4" want="$5" texts="$6"
  rm -rf "$WORK/c"; mkdir -p "$WORK/c" || { echo "cannot measure: work dir"; exit 2; }
  printf '%s' "$sc" > "$WORK/c/sc.json"; printf '%s' "$pvcs" > "$WORK/c/pvc.json"
  out="$(W="$WORK/c" bash -c '
    set -uo pipefail
    record() { echo "$1|$2|${3:-}"; }
    kubectl() {
      case "$*" in
        "get storageclass -o json") [[ "$(cat "$W/sc.json")" == "-" ]] && { echo "Error from server (Forbidden): storageclasses.storage.k8s.io is forbidden" >&2; return 1; }; cat "$W/sc.json" ;;
        "get pvc -A -o json") [[ "$(cat "$W/pvc.json")" == "-" ]] && { echo "Error from server (Forbidden): persistentvolumeclaims is forbidden" >&2; return 1; }; cat "$W/pvc.json" ;;
        *) echo "STUB: unexpected kubectl $*" >&2; return 99 ;;
      esac
    }
    '"$KGET"'
    '"$block"'
  ' 2>&1)"
  if grep -q 'STUB:' <<<"$out"; then fail "$name: the row asked something unexpected: $(grep 'STUB:' <<<"$out" | head -1)"; return; fi
  local lines; lines="$(grep -c '|App state on NFS|' <<<"$out")"
  if [[ "$lines" -ne 1 ]]; then fail "$name: expected exactly one record, got $lines: $out"; return; fi
  local got msg level rest="$texts" t missing=""
  got="$(grep '|App state on NFS|' <<<"$out")"; level="${got%%|*}"; msg="${got#*|App state on NFS|}"
  while [[ -n "$rest" ]]; do
    t="${rest%% && *}"
    if [[ "$rest" == *" && "* ]]; then rest="${rest#* && }"; else rest=""; fi
    grep -qF -- "$t" <<<"$msg" || missing="${missing} \"$t\""
  done
  if [[ "$level" != "$want" || -n "$missing" ]]; then
    fail "$name: wanted $want with$missing; got: $got"
  else
    echo "PASS  $name  ->  $level: $(cut -c1-140 <<<"$msg")"
  fi
}

E0="$(with_allow)"
run_case "0 control: no violation, static and default-class PVCs ignored" "$E0" "$SC_NFS" "$CLEAN" ok "NFS class(es) sc-nas: 0 PVC(s) on them"
run_case "1 positive control: one PVC on sc-nas, not allowlisted" "$E0" "$SC_NFS" "$ONE_BAD" fail "1 PVC(s) && default/home-assistant-config (sc-nas, Bound)"
run_case "2 two NFS classes, Pending counted, static still exempt" "$E0" "$SC_TWO" "$TWO_BAD" fail "2 PVC(s) && mqtt/mosquitto-data (sc-nas, Bound) && media/films (nas-csi, Pending)"
run_case "3 no NFS class: skip, not ok" "$E0" "$SC_NONE" "$ONE_BAD" skip "no StorageClass on this cluster has an NFS provisioner"
run_case "4 StorageClasses unreadable: warn, not ok" "$E0" "-" "$CLEAN" warn "could not run kubectl get storageclass && measured nothing"
run_case "5 PVCs unreadable: warn, not ok" "$E0" "$SC_NFS" "-" warn "could not run kubectl get pvc && measured nothing"
run_case "6 allowlist glob covers bulk data" "$(with_allow 'media/*|bulk media, read by people over SMB')" "$SC_NFS" "$BULK" ok "2 PVC(s) on them, all covered by the allowlist (1 entries)"
run_case "7 allowlist covers one of two" "$(with_allow 'media/films|bulk media')" "$SC_NFS" "$BULK" fail "1 PVC(s) && media/music (sc-nas, Bound)"
run_case "8 entry added, pin not moved" "$(PIN=0 with_allow 'media/*|bulk')" "$SC_NFS" "$BULK" fail "allowlist has 1 entries but is pinned at 0"
run_case "9 entry without a reason" "$(with_allow 'media/*')" "$SC_NFS" "$BULK" fail "allowlist entries without a reason: media/*"
run_case "10 red outranks: pin mismatch is reported even with nothing to read" "$(PIN=3 with_allow 'a/b|x')" "-" "-" fail "pinned at 3"

[[ $rc -eq 0 ]] && echo "ok — row 32 gives ok/fail/warn/skip as specified across 11 cases, the positive control reports 1, and the live allowlist matches its pin"
exit $rc
