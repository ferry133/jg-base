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

### `age.key` — a different risk class, and conditional

| Credential | What it is for | Scope | Blast radius if read | Rotation |
|---|---|---|---|---|
| **`age.key`, one per customer cluster** | SOPS decryption for that cluster's secrets, and decryption of its off-site backups | One cluster per key — but factory would hold N of them | Every secret and every archive that cluster has ever written | **Effectively none.** See below |

The other three rows share a property this one does not: an Omni service-account
key, a GitHub PAT and a Cloudflare token can each be revoked and reissued the
moment exposure is suspected, and the damage stops there. `age.key` cannot.
Backups are encrypted *to* it, so rotating the key does not re-protect anything
already written — it turns every existing archive into ciphertext nobody can
open. The choice on discovering exposure is to keep using a compromised key or
to abandon the backup history. That is a materially worse position than the
other three and it should not be inferred from a table that lists them together.

**Conditional, not settled.** Whether factory holds these at all depends on
`factory-agent` 1.5 and 5.5, still open in jg-cluster-template. Today factory
handles the material in passing: generated per cluster, committed nowhere, and
re-keyed at handover with `sops updatekeys` against the customer's public key so
ciphertext is never decrypted into the repo (D6/handover). If 5.5 lands as
written — factory gating provisioning on escrow being confirmed — then factory
holds N keys and this row becomes one of the standing credentials above.

There is a second problem in that gate, raised by fleet-ops and routed to
jg-cluster-template, recorded here because this table is where someone will look
for it: `deployment-profiles` 8.3's restore drill has never been executed (8.4
says so in its own text — step 5 written as procedure, marked not executed). So
"escrow confirmed" can currently only mean *the file was written*, not *it reads
back*. Implemented as written, factory would stamp that confirmation on every
customer cluster automatically, once per delivery.

| Material | Note |
|---|---|
| Customer-cluster kubeconfig | Obtained from Omni, not from any RBAC on jcom (D2). Lifetime is an open question — see below |

## Checking a credential: assert its scope, never its validity

Every rotation in the tables above ends with a credential that has to be
confirmed. The obvious check — "does the API accept it" — separates nothing.
Measured on the fleet by the jgt-appliance session, three Cloudflare tokens, all
53 characters, all `cfut_`-prefixed, all returning `success: true`,
`status: active`, *"This API Token is valid and active"* from
`/user/tokens/verify`. One of them works. The other two are inert in two
different ways:

- **Wrong token entirely.** On jgt-appliance, `GET /zones` returns
  `{"success":true,"errors":[],"result":[]}` — not a 403, a well-formed empty
  answer. The token's id is byte-identical to `backup_r2_access_key_id` in the
  same `cluster.yaml`: it is the R2 token sitting in the DNS field.
  external-dns filters `--domain-filter` against an empty zone list, skips every
  record, and logs **nothing at all** at info level. Hours of zero log lines is
  what healthy looks like.
- **Right zone name, wrong zone.** On jgt-omni-accept the token does see
  `janncot.cc`, so the obvious assertion passes. That zone's status is `moved`
  and its nameservers are `carioca`/`luke`, while the domain is delegated to
  `marge`/`sage`. The name exists as two Cloudflare zones in two accounts, and
  the stale one holds eight complete, correct-looking records — including
  `im.janncot.cc` — for hostnames that are NXDOMAIN worldwide.

Reproduced independently from this repo's workstation, not taken on report:

```
$ curl -H 'accept: application/dns-json' \
    'https://cloudflare-dns.com/dns-query?name=janncot.cc&type=NS'
marge.ns.cloudflare.com.   sage.ns.cloudflare.com.     # dns.google agrees
$ …?name=im.janncot.cc&type=A   ->   "Status": 3       # NXDOMAIN
```

### The general form: compare material, not labels

A name is not an instance. Every failure above is the same one — the label
matched and the thing behind it was not the thing meant — so the assertion has
to compare something only the right instance can produce.

This is not a new discipline to invent here; it is already written down and
already applied. `deployment-profiles` 8.3's escrow check does not confirm that
an escrowed `age.key` exists or is named correctly. It runs `age-keygen -y` on
the escrowed copy and compares the public key that comes out against the `age:`
recipient in `.sops.yaml`, for the reason recorded at that change's
`design.md:628`: *a truncated key copy looks exactly like a good one, and the
difference only shows on the day you need it.* Identity by key material. A
same-named, wrong or truncated copy cannot satisfy it.

The three credentials here take the same shape:

| Credential | Compare this material | Against this | The trap it closes |
|---|---|---|---|
| Cloudflare DNS token | `zone.name_servers` from `GET /zones?name=$D` | the live NS delegation for the domain, via DoH, as sets | a same-named zone in an abandoned account — measured, see above |
| Omni service account | a known cluster's ID as the SA sees it | the cluster ID that Omni instance is expected to manage | an SA on a different Omni instance authenticates perfectly |
| GitHub PAT | the repository's immutable `id` / `node_id` | the id of `ferry133/jg-base` | a fork, or a same-named repo under another owner, answers every call successfully |

The pattern for choosing the material: pick the field that the wrong instance
*cannot* forge because it is assigned by the system of record — a delegation, a
cluster ID, a repository id — rather than the field a human typed, which is
exactly the field that gets typed the same way twice.

**One assertion in §2 looks like it should fall to this and does not.** 2.3a
checks that `namespace/factory` is *absent* from jg-jiahd and jgt-appliance.
Absence-by-name on a known instance is a different claim from identity-by-name,
so it does not have the failure mode above. But it inherits the problem one
level up: `NotFound` proves nothing until you know which cluster answered.
The instance is established by the kubeconfig rather than by anything in the
reply, so establish it first — confirm the API server endpoint or some object
unique to that cluster — and then read the absence. Otherwise a stale or
wrong-cluster kubeconfig returns exactly the reassuring answer the assertion is
looking for.

**Use DoH for anything about public DNS. `dig` will lie to you**, and not only on
an appliance LAN — reproduced on the operator workstation while writing this:

```
$ dig +short NS janncot.cc @1.1.1.1
k8s-gateway.network.janncot.cc.      # 1.1.1.1 was named and did not answer
```

Split-horizon sends the domain to the cluster's own k8s-gateway, which answers
even when the query explicitly names a different server. Query
`cloudflare-dns.com/dns-query` and cross-check against `dns.google/resolve`.

Long form, raw responses and the negative-control caveat:
`jgt-appliance/docs/operations/cloudflare-token-scope.md`. Case A is a live
broken credential and repairing it destroys the negative test, so the
measurement above was captured first deliberately.

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
rather than a bug.

**Decided (ferry133/jg-cluster-template#3, 2026-08-16, relayed via fleet-ops):
accept it.** A separate cluster for the IM instances may follow later to reduce
the exposure; that option is deferred, not rejected, and the current state is a
chosen waypoint rather than the end position.

So this is now an accepted risk, and the acceptance has a consequence for this
file specifically. Under the alternatives, this document would have recorded a
*residual* risk next to a technical control. Under acceptance **the document is
the control** — there is no other mitigation in place. Anything missing from the
tables above is therefore not an accepted risk but an unrecorded one, and from
outside those look identical.

Concretely, what is accepted: the blast radius of every credential above
includes *anyone who can log in to a claude-code instance on jcom*, which today
means the Auth0 allowlist in front of `cc.janncot.com` and `im.janncot.com`.

One correction worth carrying, because the obvious version of the fix does not
work: moving the `im` instance to its own cluster would not close this. `cc` and
`im` share the single `claude-code` ServiceAccount, so a jcom without `im` still
has `cc` there as cluster-admin. The version that closes it requires
`claudecode` to stop being an `apps/base/` app in this repo — i.e. gateable per
cluster and deselected on whichever cluster runs factory — which is a change to
jg-base's shared structure and has not been made.

## What this directory does and does not grant

The ServiceAccount has no Role, no RoleBinding and no ClusterRole, and
`automountServiceAccountToken: false`. That is not minimalism for its own sake:
factory's work is against Omni, GitHub and Cloudflare, its authority over
customer clusters comes from an Omni-issued kubeconfig rather than from jcom
(D2), and mounted Secrets need no API permission to read. Anything that later
needs a verb should have to add it here and justify it.

## Not yet decided

- **There is no factory image, and nothing builds one.** The change's task list
  mentions an image exactly twice — 2.8 asks that it contain no credential
  material, and `design.md:145` asks the same — and no task anywhere produces
  it. So 2.7 (verify the toolchain inside the container) and 2.8 (verify the
  image is credential-free) have nothing to inspect, and 2.4's HelmRelease
  cannot name a `repository` and `tag` without inventing them. This is a gap in
  the change rather than a decision waiting to be made: §2 assumes an artifact
  no section creates.
- **Customer-cluster credential lifetime** (`design.md:167`, task 1.5). Holding
  one long is standing risk; re-fetching each time needs Omni Admin, the item
  with the largest blast radius. Unresolved, and it also decides whether the
  `age.key` row above is conditional or standing.
- **Whether factory performs escrow at all** (5.5), and whether the restore
  drill it would attest to has ever been run (`deployment-profiles` 8.3).
- **The workload shape is settled** and recorded here so it is not re-derived:
  spike 1.1 established that Omni's resource access is the COSI state API with
  native watch, so factory is a Deployment holding a long-lived stream rather
  than a Job, speaking the Go SDK or raw gRPC rather than shelling out to
  `omnictl`, which exposes no watch flag.
- **Watch liveness.** The stream emits `state.Errored` and must be reconnected,
  and a watch that has silently stopped delivering looks exactly like a quiet
  period with no new machines. That is the same shape as `monitoring/backup`
  reporting success while uploading zero bytes; whatever runs here needs a
  positive liveness signal, not the absence of errors.
