# Omni (Sidero) — Operator Runbook

Self-hosted Sidero Omni control plane for managing Talos Linux clusters
managed by ferry133. Deployed in the `jcom` cluster, namespace `omni`.

## Current Version

- **Image:** `ghcr.io/siderolabs/omni:v1.8.1`
- **Chart:** `omni` v2.8.1 (from `ferry133.github.io/helm-charts`, fork of upstream)
- **HelmRelease values:** see `app/helmrelease.yaml`
- **Last upgrade:** 2026-05-31 (v1.6.4 → v1.8.1) — see archived OpenSpec change
  `upgrade-omni-server-v1-8`

## Architecture — Three-Repo Flow

```
┌─ siderolabs/omni (upstream, read-only) ─────────────────────────┐
│   ~/coding/omni/                                                │
│   deploy/helm/omni/  ← canonical chart at each release tag      │
│   image: ghcr.io/siderolabs/omni:vX.Y.Z (consumed directly,     │
│          we do NOT build our own image)                         │
└─────────────────────────────────────────────────────────────────┘
                   │  copy at tagged release
                   ▼
┌─ ferry133/helm-charts (our fork & redistribution) ──────────────┐
│   ~/coding/helm-charts/charts/omni/                             │
│   GitHub Actions: helm/chart-releaser-action on push to main    │
│   Published: https://ferry133.github.io/helm-charts             │
└─────────────────────────────────────────────────────────────────┘
                   │  Flux HelmRepository
                   ▼
┌─ ferry133/jg-base (this repo, cluster manifests) ───────────────┐
│   kubernetes/apps/extras/omni/omni/                             │
│   - HelmRelease pins chart version, image tag, EULA accept      │
│   - Per-cluster secrets injected via Flux postBuild substitute  │
└─────────────────────────────────────────────────────────────────┘
                   │  Flux reconcile (jcom)
                   ▼
   Running pod in `omni` namespace
```

## Upgrade Procedure

For Omni `vA.B.C → vX.Y.Z` (replace versions in the commands).

### 1. Refresh local Omni source clone

```sh
cd ~/coding/omni
git fetch --tags origin
git checkout vX.Y.Z          # detached HEAD is fine
git -C . show vX.Y.Z:deploy/helm/omni/Chart.yaml   # note upstream chart version
```

### 2. Regenerate chart fork

```sh
cd ~/coding/helm-charts
git checkout -b chore/omni-vX.Y.Z

# Wipe and replace
rm -rf charts/omni/* charts/omni/.helmignore
cp -r ~/coding/omni/deploy/helm/omni/. charts/omni/

# Verify Chart.yaml — upstream stamps both version and appVersion
head -8 charts/omni/Chart.yaml

# Lint + dry-run against our HelmRelease overrides
helm lint charts/omni
# helm template with synthetic values matching jg-base HelmRelease + overrides
```

If `helm template` surfaces unknown-key errors under our overrides, the chart's
`values.yaml` schema has changed and our HelmRelease overrides need updating
**before** the next step.

### 3. Republish to GitHub Pages

```sh
git add charts/omni/
git commit -m "chore(omni): regenerate chart from upstream vX.Y.Z"
git checkout main
git merge --ff-only chore/omni-vX.Y.Z
git push origin main
# Workflow: .github/workflows/release.yaml runs chart-releaser-action.
# Verify within ~2 min:
curl -s https://ferry133.github.io/helm-charts/index.yaml | grep -A2 'name: omni'
```

### 4. Read the EULA (only if `appVersion` crosses a minor)

`v1.7.0` added a mandatory EULA. Re-read https://siderolabs.com/eula/ if it
hasn't been refreshed. The `config.eulaAccept` block records acceptance:

```yaml
config:
  eulaAccept:
    name: "ferry133"
    email: "ferry133@gmail.com"
```

### 5. Snapshot PVC (R3 mitigation, **before** push)

⚠ **The Omni image is distroless** — `kubectl exec ... tar` from inside the
container does NOT work. `kubectl debug --target` with PID-share also fails to
pipe binary cleanly. The reliable path is to mount the PVC into a sidecar
busybox pod after briefly scaling Omni to 0:

```sh
# Snapshot path
SNAPSHOT=~/omni-data-snapshot-$(omni-current-version)-$(date +%Y%m%d-%H%M).tar.gz

# Scale down (Omni is single-replica, brief downtime ~30-60s)
kubectl -n omni scale deploy/omni --replicas=0
kubectl -n omni wait pod -l app.kubernetes.io/name=omni \
  --for=delete --timeout=60s

# Spin sidecar (node-pinned to satisfy local-path PV nodeAffinity)
NODE=$(kubectl get pv $(kubectl -n omni get pvc omni-local \
  -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')

cat <<EOF | kubectl -n omni apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: omni-snapshot
spec:
  nodeName: $NODE
  restartPolicy: Never
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sleep", "300"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: omni-local
EOF
kubectl -n omni wait pod/omni-snapshot --for=condition=Ready --timeout=60s

# Tar /data to local file
kubectl -n omni exec omni-snapshot -- tar czf - /data 2>/dev/null > "$SNAPSHOT"
ls -lh "$SNAPSHOT"   # must be > 0 bytes
tar tzf "$SNAPSHOT" | head -10   # must list data/etcd/member/snap/db

# Cleanup + bring Omni back
kubectl -n omni delete pod omni-snapshot --wait
kubectl -n omni scale deploy/omni --replicas=1
kubectl -n omni wait pod -l app.kubernetes.io/name=omni \
  --for=condition=Ready --timeout=120s
```

Keep the snapshot file for at least the duration of post-upgrade verification.

### 6. Update jg-base HelmRelease + push

```sh
cd ~/coding/jg-base
git checkout -b chore/omni-vX.Y.Z

# Edit kubernetes/apps/extras/omni/omni/app/helmrelease.yaml:
#  spec.chart.spec.version: 'X.Y.Z'   ← chart version
#  values.image.tag: "vX.Y.Z"          ← image tag
#  values.config.eulaAccept (only needed if not already present)

# Validate locally
kustomize build kubernetes/apps/extras/omni/omni/app

git add kubernetes/apps/extras/omni/omni/app/helmrelease.yaml
git commit -m "feat(omni): upgrade to vX.Y.Z"
git checkout main && git merge --ff-only chore/omni-vX.Y.Z
git push origin main
```

### 7. Force Flux reconcile + watch rollout

```sh
env KUBECONFIG=~/coding/jcom/kubeconfig \
  flux reconcile source git jg-base -n flux-system
env KUBECONFIG=~/coding/jcom/kubeconfig \
  flux reconcile source helm my-helm-repo -n omni
env KUBECONFIG=~/coding/jcom/kubeconfig \
  flux reconcile kustomization extras-omni -n flux-system
env KUBECONFIG=~/coding/jcom/kubeconfig \
  flux reconcile helmrelease omni -n omni

kubectl -n omni get pods -w   # wait for new pod Ready
```

## Verification Commands

```sh
# Image
kubectl -n omni get pod -l app.kubernetes.io/name=omni \
  -o jsonpath='{.items[0].spec.containers[0].image}'

# UI
curl -sI https://omni.janncot.com/

# Logs (no EULA / panic / migration errors expected)
kubectl -n omni logs deploy/omni --tail=200 \
  | grep -iE 'eula|panic|migration|fatal'

# PVC preserved
kubectl -n omni get pvc

# SideroLink machines (visual check in Omni UI)
# Open https://omni.janncot.com/ → Machines page
```

## Rollback Procedure

```sh
# 1. Revert the HelmRelease commit
cd ~/coding/jg-base
git revert <upgrade-commit-sha>
git push origin main

# 2. Force reconcile
env KUBECONFIG=~/coding/jcom/kubeconfig \
  flux reconcile source git jg-base -n flux-system
env KUBECONFIG=~/coding/jcom/kubeconfig \
  flux reconcile helmrelease omni -n omni

# 3. Wait for old version pod
kubectl -n omni get pods -w

# 4. If old version pod crashloops (PVC schema migrated by new version,
#    cannot be read by old version), restore from the snapshot taken
#    in step 5 of upgrade procedure:
kubectl -n omni scale deploy/omni --replicas=0
kubectl -n omni wait pod -l app.kubernetes.io/name=omni \
  --for=delete --timeout=60s

# Spin sidecar pod (same pattern as snapshot, but writable)
# (full YAML in OpenSpec change upgrade-omni-server-v1-8 Task 10.5)
# Inside sidecar: wipe /data, untar snapshot back into /data, exit

kubectl -n omni scale deploy/omni --replicas=1
```

## Troubleshooting

### omnictl auth fails with `no such file or directory` + `stream closed without trailers`

Known limitation as of 2026-05-31.

The omnictl PGP-keypair auto-bootstrap depends on streaming gRPC
(`AwaitPublicKeyConfirmation`). The cloudflared tunnel that proxies
`omni.janncot.com` is configured without the `service: grpc://` scheme, so
trailers from the streaming response are stripped at the Cloudflare edge.
The client treats this as a failure even though the server-side log shows
`RegisterPublicKey` returned OK.

**Resolution:** see follow-up OpenSpec change `fix-cloudflared-grpc-omni`.

**Workaround for downloading talosconfig / cluster artifacts:**
- Use the Omni UI at https://omni.janncot.com/
- Navigate to cluster → Download → talosconfig / kubeconfig / cluster template
- (Browser auth works because UI requests are not affected by the gRPC trailer
  issue — `Omniconfig` and Auth0 OIDC use unary RPCs only.)

### Pod fails to start with EULA error

Add the `eulaAccept` block to `values.config` in the HelmRelease.

### Pod fails to start after upgrade — chart schema mismatch

Compare the v1.7+ chart's `values.yaml` against our HelmRelease overrides. The
v1.7 `helmvaluesgen` tool restructures the `config:` block at each upstream
release; some keys may need migration. Roll back, fix overrides, re-deploy.

### Etcd quorum warnings in logs about `jgu5-control-planes`

`Etcd members count is equal to the minimum quorum 2` — this is a pre-existing
warning about the *managed* `jg-jiahd` cluster having 2 etcd members, not about
Omni's own etcd. Tracked separately as the 2-node → 3-node etcd HA expansion P1.

## Related

- Upstream Omni: https://github.com/siderolabs/omni
- Sidero EULA: https://siderolabs.com/eula/
- Our chart fork: https://github.com/ferry133/helm-charts/tree/main/charts/omni
- OpenSpec change archive: `openspec/changes/archive/2026-05-31-upgrade-omni-server-v1-8/`
- Follow-up gRPC ingress change: `fix-cloudflared-grpc-omni` (planned)
