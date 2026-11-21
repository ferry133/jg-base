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
| UniFi console position | `im/netdev/` (overlay of `im/enabled/`) | adds only the `netdev-mcp` sidecar and its reader Secret mount (#222); `scripts/check-netdev-overlay.sh` holds "adds, changes nothing" |
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

Both claims (`im-claude-config`: `~/.claude` + the OAuth credential — a
`.credentials.json` at the claim root, and NOT a `keyrings/` directory, because
the `subPath: keyrings` mount does not take effect on 2 of 3 clusters
(`local-path`). ⚠️ That the file *holds* the login has not been read out of it;
it rests on the filename, on hit counts in a decrypted archive (2026-10-03) and
on a 2026-08-23 running-pod measurement of the same file on the factory claim.
See ferry133/jg-base#145 and #150;
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

## `im/chamber` — a component, off by default (#248)

`im/chamber` is not a position of the `claude-code-im` switch. It is a kustomize
component that adds im's chamber identity (a `chamber-bridge` container, a
socket volume, the login credential, the signer list) to whichever position a
cluster is on. Nothing in this repo references it.

- **Turning it on** is one line on the cluster's own `claude-code-im`
  Kustomization: `spec.components: [../chamber]`. It changes an existing im
  pod, so it needs the operator's approval; it is never done by a merge here.
- **It cannot be combined with `im/disabled`.** The component copies the app
  container's image pin, and `im/disabled` has no app container: the build
  fails, the Kustomization stops reconciling and therefore stops pruning — an
  im that was meant to be switched off stays. Whatever sets `components` must
  drop it when the path is `im/disabled`.
- **The credential** is the Secret `im-chamber` (keys `token`, `url`), brought
  by the cluster's own repo, optional, mounted as two files into the bridge
  container only. Nothing reads it through env: the chart refuses an optional
  `secretKeyRef`, and a required one would keep the container from starting.
  That keeps it out of `app`'s files and environment. It does **not** keep it
  from `app`: the pod's ServiceAccount is `cluster-admin` and can read any
  Secret through the API.
- **The bridge's state** (`sync-state`: the sync position and the counts not
  yet announced) lives on a claim of its own, `chamber-state` (128Mi, the
  config tier's class, mounted into the bridge only), through
  `CHAMBER_STATE_DIR` (#256). The socket stays on the memory emptyDir. Before
  #256 the state sat next to the socket, so a replaced pod started "from now"
  and a message that had arrived but was never announced was never announced.
  The claim has no `retain`: turning the component off deletes it, and what is
  lost is only a position.
- **`signers/`** is the list of people whose signed words count as a directive
  on every cluster, and the keys that no longer do. A change to either file
  needs the operator's approval before merge.
- Guard: `scripts/check-chamber-component.sh` (and `--self-test`).
