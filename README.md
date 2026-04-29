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
      kube-system/      ← cilium, coredns, metrics-server, reloader
      network/          ← cloudflare-dns, cloudflare-tunnel, envoy-gateway, k8s-gateway
      storage/          ← namespace only (provisioner is an extra)
    extras/             ← opt-in per user
      claude-code/      ← own namespace
        ks.yaml
        app/
      default/          ← apps in default namespace
        echo/
        trello-notifier/
      network/          ← apps in network namespace
        cloudflare-tunnel-lan/
      storage/
        nfs-subdir/
  components/
    sops/               ← cluster-secrets Flux component
  flux/
    cluster/            ← Flux entry point (→ apps/base/)
```

### Available Extras

| Extra | Description | Requires |
|-------|-------------|----------|
| `extras/claude-code` | Claude Code web IDE (ttyd) | NAS |
| `extras/storage/nfs-subdir` | NFS storage provisioner (`sc-nas`) | NAS |
| `extras/default/trello-notifier` | Trello LINE notification bot | — |
| `extras/network/cloudflare-tunnel-lan` | Cloudflare tunnel for LAN-only access | — |
| `extras/default/echo` | HTTP echo service (debug/test) | — |

## Setting Up a New User Cluster

Use [`ferry133/jg-cluster-template`](https://github.com/ferry133/jg-cluster-template) — click **"Use this template"** to generate a per-user private repo, then follow its README.

The per-user repo's `flux/cluster/ks.yaml` references this repo's paths. Use `per-user-repo.sample.yaml` in this repo as the reference for writing that file.

### cluster-secrets keys

All required `${VARIABLE}` keys are documented in:
`kubernetes/components/sops/cluster-secrets.sample.yaml`

## Post-Installation

### Verification

```sh
flux check
flux get sources git flux-system
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

3. In GitHub → Settings → Webhooks → Add webhook:
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
