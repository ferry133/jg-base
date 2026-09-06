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

## `im` runs `latest` — on purpose, and it costs three things

Ruled by ferry133 2026-09-06, against this repo's tag@digest pinning
convention (`extras/factory` documents why pinning exists — a tag/digest
divergence bit on 2026-08-18). What is bought: a `k8scc` push to main updates
every cluster's support terminal with no jgct edit and no re-render of ~20
user repos (the template-drift trap where `task configure` exits 0 while
nothing changed). What it costs:

1. **No pinned rollback.** The running version appears in no git repo;
   rolling back means pushing a revert build to `latest`.
2. **Fleet drift until pods restart.** Flux sees no change on a new `latest`,
   so nothing restarts; two clusters can run different code under the same
   label, and `image: latest` reads identical whether current or six months
   stale — an undiscriminating check.
3. **GHCR on the start path.** `:latest` implies `imagePullPolicy: Always`,
   so every pod start needs GHCR reachable; a pinned tag's `IfNotPresent`
   survived a registry outage on cached nodes.

Accepted for `im` because a support terminal wants freshness more than
determinism. The factory variant and anything else stays pinned.

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
`CLAUDECODE_AUTH0_DOMAIN`, `CLAUDECODE_ALLOWED_EMAILS` (comma-separated — an
initContainer splits it to one-per-line inside the pod, because postBuild
substitution collapses newlines in multi-line values),
`CLAUDECODE_CONFIG_STORAGE_CLASS`, `DEFAULT_STORAGE_CLASS`, plus the
`claude-code-secret` / `talos-mcp-secret` keys in `app/`. Empty allowlist ⇒
oauth2-proxy admits nobody: fail closed, not open.
