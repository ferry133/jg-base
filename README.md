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
      default/          ← namespace only
      flux-system/
        flux-operator/
        flux-instance/
      kube-system/      ← cilium (CNI), metrics-server, reloader, spegel
      network/          ← cloudflare-dns, cloudflare-tunnel, envoy-gateway, k8s-gateway
      storage/          ← namespace only (provisioner is an extra)
    extras/             ← opt-in per user (selected via cluster.yaml)
      claudecode/
        claude-code/    ← Claude Code web IDE
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
        nfs-subdir/
  components/
    sops/               ← cluster-secrets Flux component
  flux/
    cluster/            ← Flux entry point (→ apps/base/ + extras/)
```

## Available Extras

| Extra | Description | Requires |
|-------|-------------|----------|
| `claudecode/claude-code` | Claude Code web IDE | NAS (`nas_*`) + `claude_instances` |
| `default/echo` | HTTP echo service (debug/test) | — |
| `default/homebridge` | Homebridge smart home bridge | — |
| `default/mariadb` | MariaDB database | — |
| `default/mqtt` | MQTT broker | — |
| `default/postgres` | Shared PostgreSQL | `postgres_password` |
| `default/synophoto` | Synology Photo Tagger web UI | `synophoto_auth0_*` |
| `default/trello-notifier` | Trello LINE notification bot | Trello/LINE tokens |
| `default/ttyd` | Web terminal | `ttyd_credential` |
| `freepbx/freepbx` | FreePBX / Asterisk PBX | `freepbx_mysql_*` |
| `ingress-nginx/ingress-nginx` | Nginx ingress controller | — |
| `network/cloudflare-tunnel-lan` | Cloudflare tunnel for LAN access | — |
| `omni/omni` | Sidero Omni cluster manager | `omni_gpg_key` + `storage/local-path-provisioner` |
| `storage/local-path-provisioner` | Local-path storage class (`local-path`) | — |
| `storage/nfs-subdir` | NFS storage provisioner (`sc-nas`) | NAS (`nas_*`) |

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
