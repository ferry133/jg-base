# claude-code — the fleet's web terminal

Every cluster ships one Claude Code web terminal at `im.<domain>` (image built
from `ferry133/k8scc`). This app is the reason ferry133 always has a remote
support path that does not depend on Omni/SideroLink being up.

## Layout

| Piece | Where | Why there |
|---|---|---|
| namespace, `cluster-admin` SA/RBAC, chart `OCIRepository`, secrets | `app/` (Kustomization `claude-code`) | shared by every instance |
| the default `im` instance | `im/enabled/` (Kustomization `claude-code-im`) | static since 2026-09-06 — every per-cluster difference is a Flux `${VAR}` from cluster-secrets, so no template-time structure remains |
| opt-out position | `im/disabled/` (empty) | prune-not-suspend; see `im-ks.yaml` for the three states |
| extra instances (`cc.jiahd.cc`, per-client shells, basic-auth fallback) | per-user repos, rendered from jg-cluster-template `claude_instances` | instance names and sidecar presence are still template-time structure |

`claude-code-im` ships `suspend: true` here and is switched on by a
jg-cluster-template patch on re-render — that ratchet is what keeps it from
fighting a user repo that still renders the pre-2026-09 per-user `im`
HelmRelease over the same object name.

## `im` is pinned by digest — `latest` lasted one day, and #66 is why

Ruled by ferry133 2026-09-06 (superseding his same-day `latest` directive,
which bought fleet-wide updates on a bare `k8scc` push). `latest` did not
survive contact with spegel: the mirror resolves a mutable tag from whichever
node still caches it, so on a multi-node cluster the tag freezes at whatever
was cached first. Measured on jg-jiahd the same day (#66): the pod restarted,
kubelet said "Successfully pulled … in 200ms", the Deployment said Running —
and it was a months-old image with a CrashLooping talos-mcp. Three green
signals, zero discrimination; `imagePullPolicy: Always` does not help because
it asks the mirror, and the mirror answers with the frozen digest.

So `im` follows the same tag@digest convention as everything else
(`extras/factory` documents the original tag/digest divergence that started
it). What the pin costs — an update now requires a jg-base commit — is paid
by `scripts/bump-claudecode-image.sh`: run it after a k8scc build, review the
diff, push; Flux rolls the fleet within the hour, every update is visible in
git, and rollback is a revert instead of a race to push another `latest`.
The remaining cost is real: someone (or k8scc's CI, if that automation is
ever built — tracked in k8scc) has to run it, or the fleet quietly stays on
the old pin. That failure mode is at least the visible-in-git kind, which
`latest`-on-spegel was not.

## PVC adoption / survival

Both claims (`im-claude-config`: `~/.claude` + keyring = OAuth login;
`im-claude-workspace`) render with `retain: true` →
`helm.sh/resource-policy: keep`. Helm uninstall (opt-out prune, migration)
leaves them in place, and a later release named `im` adopts them — same
release name, same claim names. The claims left behind by the pre-2026-09
per-user `im` release did NOT carry the annotation: the migration runbook has
fleet-ops annotate them by hand *before* the re-render that prunes the old
release.

## Config reaches `im` at runtime, not render time

From cluster-secrets via `postBuild` (all rendered by jg-cluster-template into
each user repo's `cluster-secrets.sops.yaml`): `SECRET_DOMAIN`,
`FACTORY_AUTH0_DOMAIN`, `FACTORY_ALLOWED_EMAILS` (the factory tenant since #75 —
rendered from each cluster directory's gitignored `auth0.json`; comma-separated — an
initContainer splits it to one-per-line inside the pod, because postBuild
substitution collapses newlines in multi-line values),
`CLAUDECODE_CONFIG_STORAGE_CLASS`, `DEFAULT_STORAGE_CLASS`, plus the
`claude-code-secret` / `talos-mcp-secret` keys in `app/`. Empty allowlist ⇒
oauth2-proxy admits nobody: fail closed, not open.
