# Spegel — ⚠️ breaks single-node clusters

[Spegel](https://github.com/spegel-org/spegel) is a **peer-to-peer OCI image mirror**:
each node serves images it has already pulled to its peers, so the cluster pulls each
image from the upstream registry once instead of once per node. **It only makes sense
on multi-node clusters.**

This base (`jg-base`) deploys Spegel **unconditionally** to every cluster that consumes
it. The upstream cluster-template, by contrast, only enables it when there is more than
one node (`spegel_enabled = len(nodes) > 1`). On a **single-node** cluster Spegel is
pointless and actively harmful — see below.

## Why it breaks single-node clusters

1. Spegel writes a containerd registry-mirror config on each node at
   `/etc/cri/conf.d/hosts/_default/hosts.toml`, pointing **all** registries at its own
   per-node endpoints (`http://<node-ip>:29999` hostPort and `:30021` NodePort), with
   **no upstream fallback**.
2. On a single node the Spegel DaemonSet often never reaches Ready → the Flux
   `HelmRelease/spegel` goes `Stalled` and the DaemonSet is removed.
3. The poisoned `hosts.toml` stays behind. containerd now routes every pull to a
   **dead** mirror → **all un-cached image pulls fail** cluster-wide:
   ```
   failed to resolve reference "docker.io/<img>":
   Head "http://<node-ip>:29999/v2/...": dial tcp <node-ip>:29999: connect: connection refused
   ```
   Already-cached images keep running, so this can hide for weeks until a pod is recreated.

## How a single-node cluster should disable it

Spegel can't be removed from `jg-base` (multi-node clusters need it). Disable it
**per-cluster** in the consuming repo by suspending the `spegel` child Kustomization
from the umbrella `cluster-apps-base` Kustomization, then clean up the leftovers once.

**1. GitOps — stop Flux recreating it** (in the per-cluster repo's
`kubernetes/flux/cluster/ks.yaml`, under `cluster-apps-base` `spec.patches`):

```yaml
    - patch: |-
        apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        metadata:
          name: spegel
          namespace: flux-system
        spec:
          suspend: true
      target:
        group: kustomize.toolkit.fluxcd.io
        kind: Kustomization
        name: spegel
```
> Scalar-only strategic merge — does not touch `spec.patches`, so any generic
> HR-strategy patch on child Kustomizations is preserved.

**2. Remove the failed release + orphans** (a stalled HelmRelease does NOT
helm-uninstall on deletion — clean by label):
```sh
kubectl -n kube-system delete helmrelease spegel
kubectl -n kube-system delete svc,sa,servicemonitor -l app.kubernetes.io/instance=spegel
kubectl -n kube-system delete secret -l owner=helm,name=spegel
```

**3. Remove the stale node mirror config** — `kubectl debug node`'s `/host` is
read-only on Talos, so mount the path read-write via a hostPath pod:
```sh
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: spegel-hosts-cleanup, namespace: kube-system }
spec:
  restartPolicy: Never
  nodeName: <node>            # the single node
  hostNetwork: true
  tolerations: [{ operator: Exists }]
  containers:
    - name: cleanup
      image: docker.io/library/busybox:1.36   # node-cached
      imagePullPolicy: IfNotPresent
      securityContext: { privileged: true }
      command: ["sh","-c","rm -fv /hosts/_default/hosts.toml"]
      volumeMounts: [{ name: hosts, mountPath: /hosts }]
  volumes:
    - name: hosts
      hostPath: { path: /etc/cri/conf.d/hosts, type: Directory }
YAML
kubectl -n kube-system wait --for=jsonpath='{.status.phase}'=Succeeded pod/spegel-hosts-cleanup --timeout=60s
kubectl -n kube-system delete pod spegel-hosts-cleanup
```
containerd reads `hosts.toml` per pull — no node/containerd restart needed.

**Verify:** an un-cached image pulls again, e.g.
`kubectl run pull-test --image=docker.io/library/hello-world:latest --image-pull-policy=Always --restart=Never`.

## Worked example

Applied on the single-node **jcom** cluster on 2026-06-27 (node `jcom-0-0`,
`10.9.8.10`). Full write-up with exact output: `jcom` repo →
`docs/runbooks/spegel-disabled-single-node.md` (commit `fd36278`).

> TODO (optional, proper fix at the source): make this Kustomization conditional on
> node count instead of relying on each single-node cluster to opt out.
