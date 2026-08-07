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
      storage/          ← nfs-subdir (sc-nas storage class)
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
        omni/           ← Sidero Omni (requires storage/local-path-provisioner)
      storage/
        local-path-provisioner/
  components/
    sops/               ← cluster-secrets Flux component
  flux/
    cluster/            ← Flux entry point (→ apps/base/ + extras/)
```

## Available Extras

> `claudecode/claude-code` is **not** an extra any more — it is a base app installed on
> every cluster (one instance at `im.<domain>` by default, renamed via `claude_instances`).
> Only its optional dedicated database is still opt-in.

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
| `omni/omni` | Sidero Omni cluster manager | `omni_gpg_key` + `storage/local-path-provisioner` |
| `storage/local-path-provisioner` | Local-path storage class (`local-path`) | — |

## Migration: `claude-code` + `daily-check` extras → base (2026-08-07)

New clusters need nothing. Clusters that already ran either app as an extra
(jg-jiahd, jcom) need one pre-push step — **already applied to both on 2026-08-08**,
so for those two only the push and re-render remain.

Nothing is recreated by this move — the object names are unchanged, so the new owners
adopt the existing objects in place:

| Object | before | after |
|---|---|---|
| `Kustomization/claude-code` | owned by `extras-claude-code` | owned by `cluster-apps-base` |
| `Kustomization/daily-check` | owned by `extras-daily-check` | owned by `cluster-apps-base` |
| `HelmRelease/cc` | owned by `extras-claude-code-instances` | owned by `claude-code-instances` |
| `Namespace/monitoring` | in `daily-check`'s inventory (from `app/`) | owned by `cluster-apps-base` |

The one hazard is timing: the parent `flux-system` Kustomization deletes the old
`extras-*` Kustomizations, and their finalizers prune whatever still carries their
ownership labels at that instant. For `HelmRelease/cc` that would mean a Helm uninstall,
taking the `claude-config` / `claude-workspace` PVCs with it.

**Pre-push step — annotate the objects that must survive.** Do this before pushing;
it is order-independent and permanent (Flux never owns this annotation's field, so
reconciles do not strip it), which is why it is preferred over suspending
`flux-system` and patching `spec.prune: false` — Flux *does* own `spec.prune` and
reverts that patch on the next reconcile.

```sh
A=kustomize.toolkit.fluxcd.io/prune=disabled
kubectl -n claudecode  annotate helmrelease   cc          $A --overwrite
kubectl -n flux-system annotate kustomization claude-code $A --overwrite
kubectl -n flux-system annotate kustomization daily-check $A --overwrite
kubectl                annotate namespace     monitoring  $A --overwrite
kubectl                annotate namespace     claudecode  $A --overwrite
```

Then push jg-base, and in the per-user repo drop `- claudecode/claude-code` and
`- monitoring/daily-check` from `cluster.yaml`'s `extras:` list (belt-and-braces — the
renderer skips both either way), `task configure --yes`, commit, push.

```sh
flux reconcile source git jg-base
kubectl -n flux-system get kustomization claude-code claude-code-instances daily-check
kubectl -n claudecode  get pod,pvc
kubectl -n monitoring  get cronjob,secret,configmap
# once the new owners are confirmed, remove any leftovers Flux did not prune
kubectl -n flux-system delete kustomization \
  extras-claude-code extras-claude-code-instances extras-daily-check --ignore-not-found
```

Second safety net, already in place: `sc-nas` is provisioned by nfs-subdir with
`archiveOnDelete: "true"`, so even a real PVC delete only *renames* the directory on the
NAS to `archived-pvc-<uid>` under `${NAS_PATH}`. The `cc` terminal's data is recoverable
by hand in the worst case.

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
