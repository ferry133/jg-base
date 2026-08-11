# jg-base

Shared Kubernetes home-ops base repository, managed by ferry133 for ~20 clusters.

**Architecture:**
- **`jg-base`** (this repo, public) — common manifests watched by all user clusters via Flux
- **Per-user repo** (private, generated from [`jg-cluster-template`](https://github.com/ferry133/jg-cluster-template)) — cluster secrets + Flux entry point
- **`jg-jiahd`** — ferry133's own cluster, maintained separately

A single change pushed to `jg-base` automatically propagates to all clusters that have the relevant base or extra enabled.

## Two-layer Variable Strategy

| Type | Mechanism |
|------|-----------|
| **Values** (IP, domain, password) | Flux `${VARIABLE}` substituted at runtime from `cluster-secrets` |
| **Structure** (which extras, how many instances) | ferry133 renders via `task configure` in per-user repo |

## Directory Structure

```
kubernetes/
  apps/
    base/               ← installed on every cluster
      cert-manager/
      claudecode/
        claude-code/    ← Claude Code web IDE (instances rendered per-user)
      default/          ← namespace only
      flux-system/
        flux-operator/
        flux-instance/
      kube-system/      ← cilium (CNI), coredns, metrics-server, reloader, spegel
      monitoring/
        daily-check/    ← daily health-check CronJob → email + healthchecks.io
      network/          ← cloudflare-dns, cloudflare-tunnel, envoy-gateway, k8s-gateway
      storage/          ← local-path-provisioner (always) + nfs-subdir (only with a NAS)
    extras/             ← opt-in per user (selected via cluster.yaml)
      claudecode/
        postgres/       ← dedicated PostgreSQL for claude-code
      default/
        echo/
        homebridge/
        mariadb/
        mqtt/
        postgres/
        synophoto/
        trello-notifier/
        ttyd/
      freepbx/
        freepbx/
      ingress-nginx/
        ingress-nginx/
      network/
        cloudflare-tunnel-lan/
      omni/
        omni/           ← Sidero Omni
  components/
    sops/               ← cluster-secrets Flux component
  flux/
    cluster/            ← Flux entry point (→ apps/base/ + extras/)
```

## Available Extras

> `claudecode/claude-code` is **not** an extra any more — it is a base app installed on
> every cluster (one instance at `im.<domain>` by default, renamed via `claude_instances`).
> Only its optional dedicated database is still opt-in.
>
> `storage/local-path-provisioner` is **not** an extra either, as of 2026-08-11 — every
> cluster gets the `local-path` class, NAS or not. See the migration note below.

| Extra | Description | Requires |
|-------|-------------|----------|
| `claudecode/postgres` | Dedicated PostgreSQL for claude-code (MCP memory server) | `claudecode_postgres_password` |
| `default/echo` | HTTP echo service (debug/test) | — |
| `default/homebridge` | Homebridge smart home bridge | — |
| `default/mariadb` | MariaDB database | — |
| `default/mqtt` | MQTT broker | — |
| `default/postgres` | Shared PostgreSQL | `postgres_password` |
| `default/synophoto` | Synology photo workflow (GPS tagger + auto-move + AI-curated progress albums). Lives in ns `linebot` to share `linebot-admin` for project metadata (sites table, photo_folder slugs). | `synophoto_flask_secret_key`, `anthropic_api_key` |
| `default/trello-notifier` | Trello LINE notification bot | Trello/LINE tokens |
| `default/ttyd` | Web terminal | `ttyd_credential` |
| `freepbx/freepbx` | FreePBX / Asterisk PBX | `freepbx_mysql_*` |
| `ingress-nginx/ingress-nginx` | Nginx ingress controller | — |
| `network/cloudflare-tunnel-lan` | Cloudflare tunnel for LAN access | — |
| `omni/omni` | Sidero Omni cluster manager | `omni_gpg_key` |

## Migration: `claude-code` + `daily-check` extras → base (2026-08-07)

New clusters need nothing. jg-jiahd and jcom were migrated on 2026-08-08 — read the
post-mortem below before repeating this on any other cluster.

Nothing *should* be recreated by the move: every object name is unchanged, so the new
owners can adopt the existing objects in place.

| Object | before | after |
|---|---|---|
| `Kustomization/claude-code` | owned by `extras-claude-code` | owned by `cluster-apps-base` |
| `Kustomization/daily-check` | owned by `extras-daily-check` | owned by `cluster-apps-base` |
| `HelmRelease/cc` | owned by `extras-claude-code-instances` | owned by `claude-code-instances` |
| `Namespace/monitoring` | in `daily-check`'s inventory (from `app/`) | owned by `cluster-apps-base` |

The hazard is timing. The parent `flux-system` Kustomization applies the new ks.yaml and
prunes the old `extras-*` Kustomizations in the same reconcile. If an old Kustomization's
finalizer runs before the new owner has reconciled and adopted the object, the finalizer
prunes it. For `HelmRelease/cc` that means a Helm **uninstall**, taking the
`claude-config` / `claude-workspace` PVCs with it.

### Do this — suspend the parent, then disable prune on the old Kustomizations

```sh
# 1. freeze the parent so it cannot prune, and so it cannot revert step 2
flux -n flux-system suspend kustomization flux-system

# 2. spec.prune: false on every old Kustomization being retired
for k in extras-claude-code extras-claude-code-instances extras-daily-check; do
  kubectl -n flux-system patch kustomization $k --type=merge -p '{"spec":{"prune":false}}'
done

# 3. push jg-base; in the per-user repo drop "- claudecode/claude-code" and
#    "- monitoring/daily-check" from cluster.yaml's extras, task configure --yes, push
# 4. unfreeze — the parent now deletes the old Kustomizations, whose finalizers
#    honour spec.prune: false and cascade nothing
flux -n flux-system resume kustomization flux-system
flux reconcile source git jg-base

# 5. verify
kubectl -n flux-system get kustomization claude-code claude-code-instances daily-check
kubectl -n claudecode  get helmrelease,pod,pvc
kubectl -n monitoring  get cronjob
```

### Do NOT rely on `kustomize.toolkit.fluxcd.io/prune: disabled` alone

Annotating the live objects looks attractive — no suspend, no ordering constraint — but
**it does not survive**. kustomize-controller applies with server-side apply and
force-conflicts, so the moment the *new* owner applies the object from git (the git
manifests carry no such annotation) it takes over `metadata.annotations` and the
annotation is gone. Verified on 2026-08-08: all five annotated objects on both clusters
read back with an empty annotation after the migration.

On jg-jiahd the race happened to fall the safe way and `HelmRelease/cc` was never
touched — same object since 2026-06-04, Helm revision unchanged, pod not restarted.
On jcom it fell the other way: `cc` was pruned, Helm uninstalled, and both PVCs deleted.

The annotation is still worth setting as a second line of defence — it costs nothing and
covers the window before the new owner's first apply. It is not a substitute for step 1.

### If PVCs are lost anyway: recover from the nfs-subdir archive

`sc-nas` runs nfs-subdir with `archiveOnDelete: "true"`, so a PVC delete **renames** the
directory under `${NAS_PATH}` to `archived-<pathPattern-name>` instead of removing it.
This is what saved jcom.

```sh
# from a root pod with the provisioner root mounted (NAS exports allow uid 0 only)
ls -Ad /nas/archived-*
# confirm the archive is from the deletion you are recovering: ctime, not mtime,
# is the rename timestamp
stat -c '%z  %n' /nas/archived-<cluster>-<ns>-<pvc-name>
# copy back into the freshly provisioned directory, preserving uid/gid/timestamps
cp -a /nas/archived-<cluster>-<ns>-<pvc-name>/. /nas/<cluster>-<ns>-<pvc-name>/
```

Scale the workload to 0 before copying, and keep the `archived-` directory until the
restore is verified from inside the pod.

## Migration: `local-path-provisioner` extra → base (2026-08-11)

`local-path` is not the alternative to NFS — it is the node-local tier, and a cluster
with a NAS still needs one. PostgreSQL on NFS is wrong on fsync and lock semantics no
matter how big the NAS is, so the DB has to land somewhere else, and until now a cluster
with `storage_backend: nfs` had nowhere to put it. So the provisioner is installed
everywhere and never suspended; `storage_backend` selects which class is *default*.

Clusters affected: any whose `cluster.yaml` lists `storage/local-path-provisioner` in
`extras:`, plus any `storage_backend: local-path` cluster (the per-user template used to
add the extra implicitly). New clusters need nothing.

| Object | before | after |
|---|---|---|
| `Kustomization/local-path-provisioner` | owned by `extras-local-path-provisioner`, path `apps/extras/…` | owned by `cluster-apps-base`, path `apps/base/…` |
| `HelmRelease/local-path-provisioner` | owned by `Kustomization/local-path-provisioner` | **unchanged** |

Same race as the 2026-08-07 migration above, and the same fix — the inner Kustomization
keeps its name, so the new owner can adopt it in place, but only if it reconciles before
the old owner's finalizer prunes it:

```sh
flux -n flux-system suspend kustomization flux-system
kubectl -n flux-system patch kustomization extras-local-path-provisioner \
  --type=merge -p '{"spec":{"prune":false}}'
# push jg-base, then drop "- storage/local-path-provisioner" from the per-user
# repo's extras: and re-run `task configure --yes`, push
flux -n flux-system resume kustomization flux-system
# once cluster-apps-base owns it, delete the retired shell
kubectl -n flux-system delete kustomization extras-local-path-provisioner
```

**No data is at risk here**, unlike the claude-code migration: a Helm uninstall of this
release removes the StorageClass, Deployment and RBAC, but local-path PVs are plain
hostPath directories that no controller touches while their PVC still exists. Bound
volumes keep serving through the window — the kubelet mounts them without the
provisioner. What *does* break in that window is provisioning: any new PVC naming
`local-path` sits Pending until the class is back.

## Bootstrap Order

`task bootstrap:apps` (run once per new cluster) installs in this order:

1. **cilium** — CNI (nodes become Ready)
2. **cert-manager** — TLS certificate management
3. **flux-operator** — Flux controller
4. **flux-instance** — syncs this repo + per-user repo

After bootstrap, all subsequent changes go through Flux reconcile.

## Setting Up a New User Cluster

Use [`ferry133/jg-cluster-template`](https://github.com/ferry133/jg-cluster-template) — click **"Use this template"** to generate a per-user private repo, then follow its README.

### cluster-secrets keys

All required `${VARIABLE}` keys are documented in:
`kubernetes/components/sops/cluster-secrets.sample.yaml`

## Post-Installation

### Verification

```sh
flux check
flux get sources git -A
flux get ks -A
flux get hr -A
```

```sh
# Check gateway connectivity
nmap -Pn -n -p 443 ${cluster_gateway_addr} ${cloudflare_gateway_addr} -vv
```

```sh
# Check internal DNS (should resolve to ${cloudflare_gateway_addr})
dig @${cluster_dns_gateway_addr} echo.${cloudflare_domain}
```

```sh
kubectl -n network describe certificates
```

### GitHub Webhook

To have Flux reconcile on `git push` instead of polling:

1. Get the webhook path:

    ```sh
    kubectl -n flux-system get receiver github-webhook \
      --output=jsonpath='{.status.webhookPath}'
    ```

2. Full URL: `https://flux-webhook.${cloudflare_domain}/hook/<path>`

3. GitHub → Settings → Webhooks → Add webhook:
   - URL: above
   - Token: from `github-push-token.txt`
   - Content type: `application/json`
   - Events: push only

## Debugging

```sh
# Flux status
flux get sources git -A
flux get ks -A
flux get hr -A

# Pod status
kubectl -n <namespace> get pods -o wide
kubectl -n <namespace> logs <pod-name> -f
kubectl -n <namespace> describe <resource> <name>
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
```

### Why can't task bootstrap:apps be run repeatedly?

`task bootstrap:apps` uses helmfile to directly helm-install FluxOperator + FluxInstance. After bootstrap, Flux owns those releases. Running helmfile again conflicts with Flux's reconcile loop and causes `UPGRADE FAILED` or ownership conflict errors.

**Rule:** bootstrap once, then all changes go through git → Flux → cluster.
