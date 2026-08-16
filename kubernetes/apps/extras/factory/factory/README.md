# factory — credential inventory and blast radius

Task 2.9 of `factory-agent` (owned by `jg-cluster-template`; this repo holds §2,
tracked as ferry133/jg-base#5).

factory is the provisioning agent. It runs on jcom, in the same cluster as Omni
so it can reach it over ClusterIP gRPC — Cloudflare Tunnel breaks the gRPC
trailers `omnictl` depends on (D1, and the 2026-07-30 note in
`cluster.sample.yaml`). Being the thing that builds clusters, it is where the
fleet's highest-value credentials meet. That concentration is the point of this
document.

**Status: partially built.** The namespace, the ServiceAccount and its
(deliberately empty) RBAC exist. The workload does not — see *Not yet decided*.

## The credentials

Named in `factory-agent/design.md:145` as the reason factory is isolated at all.
None of these is in this repo; this is the inventory, not the store.

| Credential | What it is for | Scope | Blast radius if read | Rotation |
|---|---|---|---|---|
| **Omni Admin service account** | Create clusters, join machines, issue per-cluster kubeconfig | Every cluster Omni manages, present and future | Full control of the entire managed fleet, including clusters not yet built. The worst single item here | `omnictl serviceaccount renew` / recreate; update the Secret and restart factory |
| **GitHub PAT** | Create and populate each customer's private cluster repo | Every repo the token's account can reach | Write access to cluster manifests fleet-wide — a repo write is a deploy, on a 1h Flux interval, with no review gate | Revoke and reissue in GitHub; prefer a fine-grained token scoped to the repos it must create |
| **Cloudflare parent-account token** | DNS records and Tunnel credentials for each customer zone | The operator's Cloudflare account, which holds every customer zone | DNS for every customer domain: traffic redirection, certificate issuance via DNS-01, and tunnel takeover | Roll the token in the Cloudflare dashboard; scope to `Zone - DNS - Edit` plus `Account - Cloudflare Tunnel - Read` |

Per-cluster material that factory handles in passing rather than holds:

| Material | Note |
|---|---|
| `age.key` per cluster | Generated per cluster and committed nowhere. Handover re-keys with `sops updatekeys` against the customer's public key, so ciphertext never has to be decrypted into the repo (D6/handover) |
| Customer-cluster kubeconfig | Obtained from Omni, not from any RBAC on jcom (D2). Lifetime is an open question — see below |

## Blast radius has a term the design does not yet account for

`design.md:145` argues the isolation is achieved by "independent namespace/SA,
credentials never in the image, inventory recorded, rotatable". The first of
those does not hold as stated, and this is the honest place to say so.

`claudecode/claude-code/app/rbac.yaml` binds the shared `claude-code`
ServiceAccount to `ClusterRole/cluster-admin`. Measured on jcom, not inferred:

```
kubectl auth can-i '*' '*' --as=system:serviceaccount:claudecode:claude-code --all-namespaces
yes
```

Both `cc` and `im` run under that account. Kubernetes RBAC is additive and has
no deny, so **a separate namespace and a least-privilege SA constrain what
factory may do and say nothing about who may read factory.** Any principal that
can reach a claude-code instance on jcom can read every Secret in the table
above.

Nor does moving factory help: claude-code is a base app, present on every
cluster, so there is no cluster without a co-located cluster-admin.

That cluster-admin is deliberate — it is the rescue path for a cluster whose
Omni or SideroLink is down, confirmed 2026-07-26 — so this is a real trade-off
rather than a bug, and resolving it is not this directory's decision. It is
tracked as **ferry133/jg-cluster-template#3**, because the claim it falsifies is
in that repo's design. Until it is answered, the blast radius of every row above
includes *anyone who can log in to a claude-code instance on jcom*, which today
means the Auth0 allowlist in front of `cc.janncot.com` and `im.janncot.com`.

## What this directory does and does not grant

The ServiceAccount has no Role, no RoleBinding and no ClusterRole, and
`automountServiceAccountToken: false`. That is not minimalism for its own sake:
factory's work is against Omni, GitHub and Cloudflare, its authority over
customer clusters comes from an Omni-issued kubeconfig rather than from jcom
(D2), and mounted Secrets need no API permission to read. Anything that later
needs a verb should have to add it here and justify it.

## Not yet decided

- **Where the credentials live.** Kubernetes Secrets is the assumption the table
  above is written against, but jg-cluster-template#3 may move it: a process
  speaking the Omni Go SDK can fetch short-lived credentials at use time far
  more naturally than a shell can source long-lived ones from a Secret.
- **Customer-cluster credential lifetime** (`design.md:167`). Holding one long
  is standing risk; re-fetching each time needs Omni Admin, which is the item
  with the largest blast radius. Unresolved in the design.
- **The workload itself.** Spike 1.1 established that Omni's resource access is
  the COSI state API with native watch, so factory is a Deployment holding a
  long-lived stream rather than a Job, and it speaks the Go SDK or raw gRPC
  rather than shelling out to `omnictl`, which has no watch flag. Tasks 2.4
  (HelmRelease, HTTPRoute) and 2.7 (toolchain) are held until that settles.
- **Watch liveness.** The stream emits `state.Errored` and must be reconnected,
  and a watch that has silently stopped delivering looks exactly like a quiet
  period with no new machines. That is the same shape as `monitoring/backup`
  reporting success while uploading zero bytes; whatever runs here needs a
  positive liveness signal, not the absence of errors.
