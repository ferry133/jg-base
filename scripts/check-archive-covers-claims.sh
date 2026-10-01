#!/usr/bin/env bash
# Assert the claudecode state archive mounts every claim the base `im`
# HelmRelease declares.
#
# ferry133/jg-base#145 condition 3. The old discriminator was the MOUNT PATH
# inside a running pod (monitoring/backup/app/configmap.yaml:194): instances
# were discovered, never listed, because a hardcoded list "would silently miss
# whichever instance a cluster actually runs". Mounting PVCs directly removes
# the pod, and with it that discriminator -- a pod spec has to NAME the claims
# it mounts, which is exactly the hardcoded list the old comment warned about.
#
# So the list is allowed, and this guard is the thing that makes it safe: the
# subject is now the DECLARED CLAIM SET, read from the HelmRelease that
# declares it. Add a persistence key to `im` without mounting it here and the
# build fails. Without this, adding a third claim would produce an archive
# that is complete-looking and short one member -- the same silent omission,
# relocated.
#
# ⚠️ What this does NOT cover, stated because the gap is real: EXTRA instances
# (rendered into the per-user repo from `claude_instances`) have their own
# claims under their own release names, and a static pod spec in this repo
# cannot mount a claim it does not name. That half is template-time structure
# and belongs to jg-cluster-template. "The archive exists" and "the archive
# covers every instance" are different sentences.
#
# Usage: scripts/check-archive-covers-claims.sh
#   exit 0 every declared claim is mounted, 1 one is not, 2 cannot measure
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HR="$ROOT/kubernetes/apps/base/claudecode/claude-code/im/enabled/helmrelease.yaml"
AR="$ROOT/kubernetes/apps/base/claudecode/claude-code/app/state-archive.yaml"
for f in "$HR" "$AR"; do [[ -r "$f" ]] || { echo "cannot measure: $f not readable"; exit 2; }; done
command -v yq >/dev/null 2>&1 || { echo "cannot measure: yq is missing (CI installs it)"; exit 2; }

RELEASE="$(yq -r 'select(.kind == "HelmRelease") | .metadata.name' "$HR")"
[[ -n "$RELEASE" && "$RELEASE" != "null" ]] || { echo "cannot measure: could not read the HelmRelease name from $HR"; exit 2; }

# Only persistentVolumeClaim members: app-template also carries configMap and
# emptyDir entries under the same key, and demanding those be "mounted by the
# archive" would fire on correct manifests.
DECLARED="$(yq -r 'select(.kind == "HelmRelease") | .spec.values.persistence
                   | to_entries[] | select(.value.type == "persistentVolumeClaim") | .key' "$HR" | sort)"
[[ -n "$DECLARED" ]] || { echo "cannot measure: the HelmRelease declares no persistentVolumeClaim members, so 'all are covered' would be vacuous"; exit 2; }

MOUNTED="$(yq -r 'select(.kind == "CronJob")
                  | .spec.jobTemplate.spec.template.spec.volumes[]
                  | select(.persistentVolumeClaim != null) | .persistentVolumeClaim.claimName' "$AR" | sort)"
[[ -n "$MOUNTED" ]] || { echo "cannot measure: the archive CronJob mounts no persistentVolumeClaim at all"; exit 2; }

rc=0
fail() { echo "FAIL — $1"; rc=1; }

for key in $DECLARED; do
  want="${RELEASE}-${key}"
  grep -qxF "$want" <<<"$MOUNTED" \
    || fail "the base \`${RELEASE}\` HelmRelease declares persistence key '${key}' (claim ${want}) and the state archive does not mount it — the archive would be produced, uploaded and reported as a backup with that member missing"
done

# The other direction: a claim mounted here that nothing declares is either a
# typo or a claim that no longer exists, and the Job would sit Pending forever.
for claim in $MOUNTED; do
  key="${claim#${RELEASE}-}"
  grep -qxF "$key" <<<"$DECLARED" \
    || fail "the archive mounts '${claim}', which the \`${RELEASE}\` HelmRelease does not declare — a pod referencing a claim that does not exist never schedules, and 'never ran' looks a lot like 'nothing to back up'"
done

if [[ $rc -eq 0 ]]; then
  echo "PASS — $(wc -w <<<"$DECLARED" | tr -d ' ') declared claim(s) on release '${RELEASE}', all mounted by the archive, and nothing mounted that is not declared"
  echo "       ($(tr '\n' ' ' <<<"$DECLARED"))"
fi
exit $rc
