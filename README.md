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

## Migration: `monitoring/daily-check` extra → base (2026-08-07)

Only affects clusters that already had `monitoring/daily-check` in `extras:`
(jg-jiahd, jcom). The inner `daily-check` Kustomization keeps its name, so it is simply
adopted by `cluster-apps-base` — but `namespace.yaml` moved out of `app/` up to
`base/monitoring/`, and the old Kustomization still lists the `monitoring` namespace in
its inventory. Stamp the annotation on the live object **before** pushing so that
inventory drop can't cascade into deleting the namespace and everything in it:

```sh
kubectl annotate namespace monitoring \
  kustomize.toolkit.fluxcd.io/prune=disabled --overwrite
```

Then drop `- monitoring/daily-check` from the per-user `cluster.yaml` `extras:` list
(the renderer skips it either way), `task configure --yes`, push. Verify with:

```sh
kubectl -n flux-system get kustomization daily-check
kubectl -n monitoring get cronjob,secret,configmap
```

## Migration: `claudecode/claude-code` extra → base (2026-08-07)

New clusters need nothing. Clusters that **already** ran claude-code as an extra must be
migrated in order, because the Flux Kustomizations are renamed
(`extras-claude-code` → `claude-code`, `extras-claude-code-instances` →
`claude-code-instances`) and a stale Kustomization's finalizer prunes its inventory —
which would delete the HelmRelease **and its `claude-config` / `claude-workspace` PVCs**
before the new ones adopt them. The `claudecode` namespace itself is safe
(`kustomize.toolkit.fluxcd.io/prune: disabled`).

```sh
# 1. freeze the per-user entry point so the old specs can't be re-applied
flux -n flux-system suspend kustomization flux-system

# 2. stop the old Kustomizations from pruning anything on delete
kubectl -n flux-system patch kustomization extras-claude-code-instances \
  --type=merge -p '{"spec":{"prune":false}}'
kubectl -n flux-system patch kustomization extras-claude-code \
  --type=merge -p '{"spec":{"prune":false}}'

# 3. in the per-user repo: drop "- claudecode/claude-code" from cluster.yaml's
#    extras list, re-render, push. Push jg-base first if it isn't pushed yet.
task configure --yes && git add -A && git commit && git push

# 4. let Flux take it from here
flux -n flux-system resume kustomization flux-system
flux reconcile source git jg-base

# 5. verify, then clean up any leftovers Flux didn't already remove
kubectl -n flux-system get kustomization claude-code claude-code-instances
kubectl -n claudecode get pod,pvc
kubectl -n flux-system delete kustomization \
  extras-claude-code-instances extras-claude-code --ignore-not-found
```

Step 3's `cluster.yaml` edit is belt-and-braces: the renderer already skips
`claudecode/claude-code` if it is still listed, so a repo that hasn't been cleaned up
will not emit a Kustomization pointing at the removed `extras/` path.

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
