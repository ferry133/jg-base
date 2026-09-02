# factory — credential inventory and blast radius

Task 2.9 of `factory-agent` (owned by `jg-cluster-template`; this repo holds §2,
tracked as ferry133/jg-base#5).

factory is the provisioning agent. It runs on jcom, in the same cluster as Omni
so it can reach it over ClusterIP gRPC — Cloudflare Tunnel breaks the gRPC
trailers `omnictl` depends on (D1, and the 2026-07-30 note in
`cluster.sample.yaml`). Being the thing that builds clusters, it is where the
fleet's highest-value credentials meet. That concentration is the point of this
document.

**Status, remeasured 2026-08-26.** Namespace, ServiceAccount, its (deliberately
empty) RBAC *and* the workload all exist — `deploy/factory` 2/2 Running with the
HelmRelease at v3 when jcom was last measured (2026-08-23), image pinned by
digest. What this line said until now was "the workload does not [exist]", which
was true when written and stopped being true without anything in this directory
changing. That is the failure this whole document is about, arriving in the
document itself: **a record of a gap that closed reads exactly like a statement
of one that is open**, and a reader checking the image question got the wrong
answer from the same directory that contains the answer.

What is *not* yet true is the thing §2's title claims. The credentials below are
now wired into the pod (see *Where each credential is mounted*), but wiring is
not issuance: until ferry133 issues them and they reach `cluster-secrets`, every
one of them renders empty and this is a terminal, not a provisioning
environment.

## The credentials

Named in `factory-agent/design.md:145` as the reason factory is isolated at all.
None of these is in this repo; this is the inventory, not the store.

| Credential | What it is for | Scope | Blast radius if read | Rotation |
|---|---|---|---|---|
| **Omni Admin service account** | Create clusters, join machines, issue per-cluster kubeconfig | Every cluster Omni manages, present and future | Full control of the entire managed fleet, including clusters not yet built. The worst single item here | `omnictl serviceaccount renew` / recreate; update the Secret and restart factory |
| **GitHub PAT** | Create and populate each customer's private cluster repo | Every repo the token's account can reach | Write access to cluster manifests fleet-wide — a repo write is a deploy, on a 1h Flux interval, with no review gate | Revoke and reissue in GitHub; prefer a fine-grained token scoped to the repos it must create |
| ~~**Cloudflare parent-account token**~~ — **not held, by decision (2026-08-28)** | It was to write DNS records and tunnel credentials for each customer zone | — | — | Nothing to rotate. The row's premise died with D11; see *The Cloudflare credential is gone* below |
| **Cloudflare origin cert** (`~/.cloudflared/cert.pem`) — **not held, and now structurally cannot be** | Creating a tunnel. Produced by `cloudflared tunnel login`, i.e. a browser session, not an API call | The Cloudflare account whose browser session signed it | The tunnel is created in whichever account the cert belongs to — this has already caused an outage, see below | Re-run `cloudflared tunnel login` **in the customer's account**. That is a person at a browser, in an account the company does not own; it is not a credential factory can be given |

### The Cloudflare credential is gone, because its premise was

That row used to read *"the operator's Cloudflare account, **which holds every
customer zone**"*. **It does not, and the whole row was built on that clause.**

**Decided** (D11, ferry133, 2026-08-25): each customer's Cloudflare account is
registered under the customer's own Google identity. The company operates it;
it does not own it.

**Measured** (2026-08-28, and re-measured here from public data rather than
taken on report — Cloudflare DoH and Google DoH agree):

| Zone | Authoritative NS |
|---|---|
| `janncot.cc` (a D11-shaped customer) | `beth` / `hans`.ns.cloudflare.com |
| `jiahd.cc` (operator's own) | `rajeev` / `shubhi`.ns.cloudflare.com |

Cloudflare assigns an NS pair per account. **Two different pairs is two
different accounts**, which matches the differing `AccountTag` in the two
clusters' tunnel credentials.

So a token issued from the operator account **cannot touch a customer's zone**,
and the failure mode is the worst one available: the token exists, looks
correct, and does nothing — silently, in a Secret, until the first real
provisioning run, at a customer site, under time pressure.

**One argument decides this without needing the API tested — and it is not the
first one this file reached for.** The issue that raised it noted, honestly, that
nobody had watched Cloudflare reject an operator token against a customer zone.

The reason that stands is that **the credential cannot be singular, and the
Secret has one field.**

`cloudflare_token` — the one external-dns and cert-manager's DNS-01 use — lives
in each customer's *own* cluster: one per cluster, issued when it is built,
gone when it is handed over. factory is a single workload on jcom serving every
customer, so under D11 it would need **one token per customer account, held
simultaneously**, plus somewhere to keep them apart and a rule for which one
applies to which delivery. `cloudflareApiToken` is a scalar. That single field
*is* the dead premise, written down: it can only be right if one credential
reaches every customer zone, which is exactly what stopped being true.

This survives the open question below. Even if a customer issues a token scoped
to their own zone and hands it over, factory needs N of them and a per-customer
store — so the field as designed is wrong either way, and the decision does not
depend on which way that question goes.

### The argument this replaced, and why it was wrong

An earlier version of this section argued: handover is obliged to remove every
company-added account member (`fleet-ops openspec/changes/factory-agent/tasks.md`
6.4, item 3), so a credential handover must revoke cannot be one factory holds
for the life of a cluster.

**That property does not discriminate.** `fleet-ops docs/operations/handover-inventory.md`
carries `cloudflare_token` with the instruction to revoke it and not hand it
over — it is *also* a Cloudflare credential handover must revoke, and it exists,
is held, and is correct. A test that both the kept and the removed credential
pass is not a test. It was also blind to the open path below, which needs no
account membership at all and so falls outside 6.4 entirely.

Caught by the fleet-ops session that raised #44, on review. Recorded rather than
quietly swapped, because the removal is the same either way and **a decision
resting on a reason that can be knocked down gets overturned the day someone
knocks it down — and whoever overturns it will have only this paragraph to go
on.**

That also settles the origin-cert row above, in the same direction and harder:
`cloudflared tunnel login` is a browser session, and it now has to happen *in
the customer's account*. There is no shape of that which is a secret factory can
be handed.

**So: factory holds no Cloudflare credential.** The account-level work — zone
registration, tunnel creation — is a person's, which `factory-agent` 7.3 already
recorded from the other side: those runbook steps are ones an agent cannot do
*by design*, because automating them would mean holding the customer's account.

#### What is genuinely open, recorded so the absence stays a decision

A customer could issue a token scoped to their own zone and hand it to the
company. That path is **unexplored**: nobody has decided who would hold such a
token, whether it survives handover, or whether it is any better than a person
doing the step. It is written here rather than omitted for the reason this whole
file exists — **a considered exclusion and an oversight look identical from
outside**, and the next person to want Cloudflare automation should land on this
paragraph rather than on a gap.

### Historical: the Cloudflare row said `Read`, and every token issued from it could not build a tunnel

> Kept because the *method* generalises, not because the row still exists. The
> credential this describes was removed above; what survives is the shape of the
> measurement — one variable changed, everything else held.


Corrected 2026-08-26. `Read` is enough to *list* tunnels and not to *create*
one, and the difference was measured rather than argued (2026-08-23, against
jg-janncotcc's live token — which had itself been issued by following this very
row):

| Verb | Same token, same account, same path | Result |
|---|---|---|
| `GET /accounts/{id}/cfd_tunnel` | | ✅ `success=true`, four tunnels listed |
| `POST /accounts/{id}/cfd_tunnel` | | ❌ `{"code":10000,"message":"Authentication error"}` |

**The only variable is the verb**, which makes it a controlled pair rather than
a single failure — and the account-level `GET` passing rules out the competing
explanation, that this is a zone-only token which cannot reach account
endpoints at all. It reaches them; it may not write.

Two honest boundaries. `10000 Authentication error` is Cloudflare's generic
code, shared between insufficient permission and other auth failures; the verb
pair and the account read narrow it to permission, but **the token's permission
groups were never read directly**. Both readings call for the same repair — issue
one with `Tunnel:Edit` — so the correction is robust to that unknown. And no
tunnel was actually created on that attempt, so *"a tunnel can be built through
the API"* remains unproven: whether the credentials JSON can be assembled,
whether `cloudflared` accepts it, and whether the resulting tunnel reaches the
edge are all still unmeasured.

**Why nobody hit this until now, and why that matters more than the typo.**
Tunnels have so far been created interactively with
`cloudflared tunnel login` → `~/.cloudflared/cert.pem`. That origin cert is a
credential, it was not in the table above until this edit, and **it was masking
the error in the row that is**. The missing row and the wrong row are two ends
of one defect.

That missing row has already caused an outage, so it is not a theoretical
omission. `jg-janncotcc`'s tunnel was built in `Jiahdadm@gmail.com's Account`
while the `janncot.cc` zone lives in `Ferry133@gmail.com's Account`, because the
workstation's `cert.pem` belonged to the former. `external.janncot.cc` answered
HTTP 530 / error 1033 — **and every cheaper check passed**: the tunnel was
Healthy inside its own account, the pod was 1/1 with four edge connections, the
DNS record existed. It is the instance of this file's own sentence: *a row
missing from the table is not an accepted risk, it is an unrecorded one, and
from outside the two are identical.*

It is recorded here rather than deleted on the strength of the ruling, because
the API path is decided and **unverified** — the write half of that token still
returns `Authentication error`. If the API path proves out, this row becomes
"was required, removed by design"; it does not become nothing.

### `age.key` — deliberately not held, and that is the point

**factory holds no customer key material.** Decided 2026-08-17
(`ferry133/jg-cluster-template#6`, relayed via fleet-ops, ferry133's words:
*"factory doesn't do escrow. employee action."*). Escrow is performed by a
person, once per delivery, and the key never reaches factory.

This is recorded rather than simply omitted, for the same reason the empty
`rbac.yaml` in this directory says why it is empty: **an absent row and a
considered exclusion look identical.** Anyone later adding an escrow feature to
factory should hit the reasoning rather than a gap, because the exclusion is
doing real work.

The work it does: every credential factory *does* hold — Omni SA key, GitHub
PAT, Cloudflare token — can be revoked and reissued the moment exposure is
suspected, and the damage stops at that moment. An `age.key` cannot. Backups are
encrypted *to* it, so rotating does not re-protect anything already written; it
converts every existing archive into ciphertext nobody can open. The choice on
discovering exposure would be to keep using a compromised key or to abandon the
backup history.

Under (a) — see below, where this document rather than a technical control is
what stands between those credentials and a co-located cluster-admin — an
unrevocable credential sitting beside three revocable ones would have been the
worst item in the inventory by a wide margin. It is out of scope by decision,
not mitigated by a control. That is the stronger form and it should not quietly
weaken later.

Two things that would have to be true before revisiting it, neither of which is
today:

- ~~"escrow confirmed" can presently only mean *the file was written*, not *it
  reads back*.~~ **This threshold is met. It was met on 2026-08-23, and the
  2026-08-31 edit that claimed otherwise was wrong — see below.**

  `deployment-profiles` 8.3 ran on **2026-08-23** (`fleet-ops` commit
  `1b63123`, `jg-janncotcc` → `jcom`): the archive was restored using only the
  backup and the escrowed `age.key`, onto a cluster that had never held that
  data, and three tables were compared. It carries a positive control — one
  string in the restored DB was altered and the `episodes` digest moved while
  the row count stayed at 137, proving a row-count-only comparison would have
  missed it, and the untouched `knowledge` digest did not move, proving the
  difference was not an artefact of recomputing.

  So the sentence struck through above is retired, and the adjacent bullet
  further down — "reversing it would need 8.3 to have actually run first" — is
  now a **satisfied** condition rather than a blocking one.

  **What 2026-08-31 actually added** is smaller and worth stating accurately:
  the key round-trip comparison became a *runnable check*
  (`delivery-check.py escrow`) instead of a hand-performed one. 8.3's own
  Step 0 record describes the same actions on 2026-08-23, same public key. It
  was not the first time.

  **What is still open is not "has the drill run" but three things the drill
  itself recorded as outside its scope:**

  - **Escrow durability.** The passphrase lives only in `login.keychain-db`,
    with no `sync` attribute — one laptop, one copy. The 08-31 read-back does
    not touch this at all: it recovered the passphrase from that same keychain.
  - **The role trap was bypassed, not exercised.** The dump's owner role is
    `claudecode`, and `jcom` already had that role, so the restore never tested
    what happens on a cluster that does not.
  - **`jgt-appliance`'s `age_key_escrowed: true` can no longer be verified** —
    that cluster is deleted.

  That is why the attestation still should not be automated, and the reason is
  now the right one: **one cluster passing once is not every delivery passing,
  and the three items above are what a per-delivery check would have to cover.**

- Handover already re-keys with `sops updatekeys` against the customer's public
  key (D6), so ciphertext is never decrypted into the repo. Nothing about the
  current flow needs factory to hold the key.

| Material | Note |
|---|---|
| Customer-cluster kubeconfig | Obtained from Omni, not from any RBAC on jcom (D2). **Expires by handover, not by policy** — see below. Lifetime *during company management* is still open |

**An Omni-issued credential for a customer cluster stops working when that
cluster is handed over** — a property of the credential rather than a rule
someone has to remember. Ruled 2026-08-25: customer machines are removed from
Omni at handover. Control is not transferred to a customer-run Omni — nobody
runs one — so the cluster's owner is issued two credentials against their own
cluster instead.

⚠️ **That covers Omni-issued passes and nothing else, and the exception is not
hypothetical.** A `--break-glass` talosconfig is signed by the *cluster's own*
Talos CA and authenticates **straight to the nodes** — measured here on
jg-jiahd's: its `endpoints` are the three node addresses, not Omni's URL, and it
carries `crt`/`key`/`ca` where an Omni-proxy config carries none. Removing
machines from Omni does not touch the nodes' Talos PKI, so **any break-glass
certificate keeps working after handover**, and jg-jiahd is holding one with
about 335 days left. The only revocation is rotating the cluster CA, and Omni's
break-glass taint cannot tell you how many were ever issued — it is a saturating
boolean that remembers only the most recent.

So the handover statement has to be two sentences, not one. "Removed from Omni"
revokes the passes Omni issued. It says nothing about a break-glass certificate
in anyone's hands — a former employee's, or a copy in a backup. Written as one
sentence it reads as complete coverage, and a handover package would then claim
"revoked" over a credential that is still live.

The reason this belongs next to the row rather than only in the handover
document is what a 2026-08-26 remeasurement established about what these
credentials *are*. An earlier conclusion held that Omni's `Talosconfig` and
`Kubeconfig` RPCs "directly sign client certificates". They do not: an
`omnictl talosconfig` is 229 bytes with zero `crt`/`key`/`ca` fields, carrying
only Omni's own endpoints and a `siderov1` identity, and the kubeconfig has no
`client-certificate-data` either — it shells out to `oidc-login` against Omni.
**They are passes issued by Omni, not certificates issued by the cluster.**
Which means removal from Omni is not merely an administrative step that ought to
be followed by revocation; it *is* the revocation. There is no leftover to
forget.

What that does **not** settle, and what this inventory is the right place to
decide: during company management, one long-lived per-cluster credential held in
factory versus one re-minted per use with the Omni service account. That
trade-off is untouched by the ruling — it is the last open credential question
here, and it is open in both directions (standing risk versus more use of the
highest-blast-radius item).

## Where each credential is mounted

Added 2026-08-26, and the reason it did not exist before is worth one sentence:
this inventory described a design and was read as describing a deployment. Its
Omni row carried a rotation procedure ending *"update the Secret and restart
factory"* for a Secret that did not exist, and nobody had checked. The pod was
measured for the first time on 2026-08-23 and held **none** of the three.

`app/credentials-secret.yaml` and `app/helmrelease.yaml` now wire them. What is
below is the shape, because the shape is what makes the question answerable
later:

| Credential | Secret key | Reaches the container as | Env / path |
|---|---|---|---|
| Omni service account | `omniServiceAccountKey` | `env[].valueFrom.secretKeyRef` | `OMNI_SERVICE_ACCOUNT_KEY` |
| Omni endpoint | `omniEndpoint` | `env[].valueFrom.secretKeyRef` | `OMNI_ENDPOINT` |
| GitHub provisioning token | `githubToken` | `env[].valueFrom.secretKeyRef` | `GH_TOKEN` |
| ~~Cloudflare token~~ | — | **not mounted** | removed 2026-08-28; the container has no `CLOUDFLARE_API_TOKEN` and no `CF_TOKEN` |
| fleet-ops read-only deploy key | `fleetOpsDeployKey` (b64 in `data:`) | `volumes[].secret`, `subPath`, mode `0400` | `/home/claude/.ssh/fleet-ops`, reached via `GIT_SSH_COMMAND` |

All on the **`app` container only**. `oauth2-proxy` holds the three
`OAUTH2_PROXY_*` keys of `factory-secret` and nothing else — rendered and
checked, not assumed.

**`envFrom` is deliberately not used anywhere here.** A `secretRef` under
`envFrom` injects a bag of variables that appears nowhere in the pod spec, so
"does this container hold the Omni key" stops being answerable by reading the
Deployment — and the answer it gives instead is byte-identical to "it holds
nothing". That is not hypothetical: the 2026-08-23 audit concluded "zero
credentials" from an empty `env[].valueFrom.secretKeyRef` list *without asking
`envFrom`*, and happened to be right. Listed one per line, the pod spec is the
inventory. Anyone re-running that audit should ask all three shapes —
`envFrom`, `env[].valueFrom.secretKeyRef`, `volumes[].secret`.

**The `app` container runs as uid 0** (`defaultPodOptions.securityContext`,
confirmed in the rendered spec). That closes the loose thread left by the
2026-08-23 measurement: `~/.claude/.credentials.json` on the PVC is `root:root
0600`, so a non-root `app` could not read its own Claude credentials. It is
root, so it can. Read off the spec the kubelet enforces, not off `id` inside a
running container.

### Where the values come from — and why they are all empty today

Every value is a Flux `postBuild` substitution from `cluster-secrets`, so no
material is in this repo. The variables are:

| Variable | Carries |
|---|---|
| `FACTORY_OMNI_SA_KEY` | Omni service account key, `--role Operator`, short TTL |
| `FACTORY_OMNI_ENDPOINT` | override only; defaults to the in-cluster path |
| `FACTORY_GITHUB_TOKEN` | fine-grained PAT for creating customer repos |
| `FACTORY_FLEET_OPS_DEPLOY_KEY_B64` | base64 of the read-only deploy key |

⚠️ **None of these is declared in `jg-cluster-template` yet** — no
`cluster.schema.cue` field, no line in `cluster-secrets.sops.yaml.j2` — so every
one renders empty on every cluster, today, including jcom. That is sequencing,
not oversight: the consuming half is reviewable here, the declaring half is
`jg-cluster-template`'s, and the values are ferry133's to issue. **This file
landing deploys nothing**; the pod gains five env names and one zero-byte file.

Empty is legible **at the point of use**, which is the only reason it is an
acceptable interim state. `omnictl` treats an empty `OMNI_SERVICE_ACCOUNT_KEY`
as unset and refuses to authenticate, `gh` reports no token, and a zero-byte
private key fails at key load. None of them degrades into looking as though it
worked.

⚠️ **"At the point of use" is the whole of the claim, and the first version of
this paragraph overstated it.** Nothing outside the pod reports an unset
credential: measured by another session on jcom, the three credentials read
`len=0` while every external indicator stayed green. So an empty credential is
loud to whoever runs a command and **completely silent to anyone watching** —
this document's own subject, arriving once more. Do not read "legible" as
"someone will notice".

The consequence for anyone tracking this work: **declaring the variables will
not turn anything from red to green, because nothing was red.** Green before the
declaration and green after it are the same green. The only assertion that
separates "issued" from "not issued" is reading the length inside the pod, and
until something does that on a schedule, the state of these credentials is
carried by this file rather than by any check.

`FACTORY_OMNI_ENDPOINT` is the exception, and on purpose: it defaults to
`http://omni.omni.svc.cluster.local:8080` — the `omni` extra's own Service, its
`service.main.omniPort`, and `http` because that Service is h2c with TLS
terminating at the ingress. So the endpoint half of 2.6 is configured the moment
this lands, and only the credential half waits. It is a literal rather than a
required variable for the same reason `--trusted-proxy-ip` is a literal: factory
is jcom-only by D1, and no `cluster-secrets` variable carries this.

⚠️ **2.6 is configured, not exercised.** That omnictl and the Go SDK accept an
`http://` endpoint, and that Omni accepts service-account auth over cleartext
in-cluster, are both read off configuration rather than off a call. What *has*
been measured (jcom, 2026-08-18) is only the transport underneath:
`omni.omni.svc.cluster.local` resolves to `10.43.2.239` and 8080/8090/8095 are
open. The gRPC-trailer question 2.6 actually asks is untouched — and its cheap
half does not need the credential, since an *unauthenticated* stream still
returns its status in trailers, so a clean `PermissionDenied` would prove
trailers survive ClusterIP + cluster DNS. That needs `grpcurl` in the image,
which is `k8scc`'s.

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

- **Correct, for contrast.** jg-jiahd's token, indistinguishable from B by
  anything cheap: same 53 characters, same `cfut_` prefix, same `active` verify,
  and it too returns exactly one zone bearing the name asked for. It separates
  on two columns and no others — `status` is `active` rather than `moved`, and
  `name_servers` `[rajeev, shubhi]` equals the live delegation as a set.

### Three answers to one call, and what actually separates them

jgt-appliance's token was repaired on 2026-08-17, so the same field on the same
cluster has now produced a broken answer and a correct one. With B alongside,
`GET /zones?name=…` gives three results and the columns that matter are not the
ones anyone checks:

| | `http_status` | `success` | `count` | `status` | `name_servers` vs live NS | verdict |
|---|---|---|---|---|---|---|
| **A-before** | 200 | true | **0** | — | — | broken |
| **A-after** | 200 | true | 1 | `active` | match | correct |
| **B** | 200 | true | 1 | **`moved`** | **differ** | broken |

`http_status` and `success` are identical in all three and separate nothing.
`count` separates A-before from the other two and **nothing else does** — which
is why "does the API accept the token" is not a check. And `count >= 1` is not
the assertion either, because B passes it: only `status` and the NS comparison
separate B from A-after.

The two bodies, both under **HTTP 200**. A-before is a record, not something to
re-run — the credential it came from no longer exists, and the same call on that
cluster now returns A-after:

```
A-before (2026-08-16)
{"result":[],"result_info":{"page":1,"per_page":20,"total_pages":0,
 "count":0,"total_count":0},"success":true,"errors":[],"messages":[]}

A-after (2026-08-17)
{"result":[{"id":"b67776ce…","name":"janncot.cc","status":"active",
 "name_servers":["marge.ns.cloudflare.com","sage.ns.cloudflare.com"]}],
 "result_info":{…,"count":1,"total_count":1},"success":true,"errors":[]}
```

Note the zone id: `b67776ce…`, not B's `c9851d69…`. Two live zones of the same
name in two accounts, and the repaired token points at the delegated one — which
is the trap in the table above, shown rather than described.

**That the assertion tracks reality, not just itself:** after the repair,
external-dns created six records within three seconds, and `im.janncot.cc` went
from NXDOMAIN worldwide for three days — while every component reported
healthy — to serving. Confirmed here independently:

```
$ curl -I --resolve im.janncot.cc:443:172.67.166.34 https://im.janncot.cc
HTTP/2 401
www-authenticate: Basic realm="ttyd"
cf-ray: a2c3fbf118de1613-SJC
```

`--resolve` because this workstation's own resolver still cannot find the name —
see the interception note below. A host that can reach the service by address
and not by name is the same defect one layer down.

Verified here rather than taken on report — the delegation half, which is the
part that generalises:

```
$ curl -H 'accept: application/dns-json' \
    'https://cloudflare-dns.com/dns-query?name=janncot.cc&type=NS'
marge.ns.cloudflare.com.   sage.ns.cloudflare.com.     # dns.google agrees
$ …?name=im.janncot.cc&type=A   ->   "Status": 3       # NXDOMAIN
```

The token measurements are the jgt-appliance session's, not reproduced here —
calling Cloudflare with another cluster's credential is not something this
directory needs to do. What was checked locally is that shape separates nothing:
all three tokens are 53 characters with the same prefix, and jgt-appliance's
`backup_r2_access_key_id` begins `e2702`, matching the reported token id.

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

**On the appliance LAN, `dig` cannot answer questions about public DNS, and
naming a server does not help.** The scope is the resolver path, not the
location: any host whose queries traverse `10.9.1.1` is affected, and a host on
a clean network is not.

```
$ dig +short NS janncot.cc @1.1.1.1
k8s-gateway.network.janncot.cc.      # 1.1.1.1 was named and did not answer
$ dig +short A example.com @192.0.2.1    # TEST-NET-1, unroutable by definition
104.20.23.154                            # …and it answered anyway
```

An unroutable address answering proves the mechanism: the gateway transparently
redirects all outbound UDP/53, so the server named in the query is irrelevant.
It is not split-horizon resolution — that was the first guess here and it was
wrong. DoH is immune because it is HTTPS on 443, not because it is a different
provider; that is why `cloudflare-dns.com/dns-query` cross-checked against
`dns.google/resolve` is the right instrument and a second `dig` at a different
server is not.

Two corrections went into that paragraph, both worth keeping visible because
they are the failure this whole section is about. It first read as a warning
about appliance LANs; that was broadened to "everywhere" on the strength of a
reproduction from the operator workstation — which was not a second measurement,
because that workstation is `10.9.1.125`, inside jgt-appliance's own
`node_cidr` `10.9.1.0/24`, resolving via `10.9.1.1`. Same host, same path, one
data point counted twice. The broadened version would have told a reader on a
clean network that their working `dig` was untrustworthy, which is how a true
warning gets ignored.

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

The ServiceAccount has no Role, no RoleBinding and no ClusterRole. That is not
minimalism for its own sake: factory's work is against Omni, GitHub and
Cloudflare, its authority over customer clusters comes from an Omni-issued
kubeconfig rather than from jcom (D2), and mounted Secrets need no API
permission to read. Anything that later needs a verb should have to add it here
and justify it.

### `automountServiceAccountToken: false` was stated in two files and in effect in neither

Found and fixed 2026-08-26. `app/rbac.yaml` sets it on the ServiceAccount, this
paragraph asserted it, and **the pod had a token mounted anyway**: app-template
writes `automountServiceAccountToken: true` onto the pod spec by default, and
Kubernetes resolves a pod/ServiceAccount conflict in the *pod's* favour. The
fix is one line in `app/helmrelease.yaml`, at the level that actually decides.

Measured, not deduced — `helm template` against app-template 4.6.2 with `main`'s
own values rendered `automountServiceAccountToken: true`. So this has been the
state since 2.4 landed.

It is a small escalation and a large instance. The token grants close to nothing
because the SA has no bindings, so nothing was reachable that was not reachable
before. What it cost is the property this file trades on: **a control cited in
two places, believed by everyone reading either, and not in effect.** Neither
citation could have caught it, because both were describing the input rather
than the output. The render is the only thing that separates them, which is why
it is now the thing this directory checks.

The same render found a second one: the `claude-config` claim was mounted with
`globalMounts`, and *global* means every container in the controller — so
oauth2-proxy, the process terminating untrusted HTTP from the internet, had
Claude Code's own `.credentials.json` mounted at `/home/claude/.claude`. Now
`advancedMounts`, `app` only.

## Not yet decided

- **~~There is no factory image, and nothing builds one.~~ Closed 2026-08-17.**
  `k8scc` builds a factory stage, 2.7 compared its tool pins line by line, 2.8
  scanned all 28 layers of the published manifest, and
  `app/helmrelease.yaml:77` pins it by digest. Struck through rather than
  deleted, because the bullet is a small case study in its own right: it read as
  a current statement of a gap for nine days after the gap closed, in the same
  directory as the HelmRelease that closed it.
- **Customer-cluster credential lifetime** (`design.md:167`), narrowed but not
  closed. The handover half is settled — the credential dies when the machines
  leave Omni (see the customer-cluster row above). What is open is the operating
  policy while the company manages the cluster: hold one long-lived per-cluster
  credential, or re-mint per use with the Omni service account. Standing risk
  against more frequent use of the highest-blast-radius item. Still the only
  credential question open, since the `age.key` one closed by scope.

  **One side of that trade got cheaper, measured 2026-08-30/31.** Re-minting was
  costed partly on the assumption that Omni access needs an interactive browser
  login; it does not. The `claude-code` Omni service account (present since
  2026-05-16) removes that step for both `talosctl` and `kubectl` — measured
  when a fleet-ops session had, the same day, written "unattended provisioning
  cannot contain a browser step" into a runbook and marked it untested.

  ⚠️ **This lowers the cost of re-minting and says nothing about the other
  half.** The reason re-mint is not obviously right is the blast radius of using
  the Omni service account more often, and that is untouched by it being
  convenient. A cheaper option is not a safer one, and the question stays open.

  ⚠️ **And the cheaper option expires.** That service account is Admin-role with
  a TTL of 8760h, created 2026-05-16 — so it lapses around 2026-05-16 + 1 year.
  A trade-off costed on it is costed on something with an end date, which is not
  the same as a standing capability.

  It also lands on the co-located-cluster-admin risk below, in the opposite
  direction: today every agent action runs under ferry133's own Omni identity,
  so *more* use of the service account is an auditing improvement. Also not a
  conclusion — recorded so the next reader has both directions rather than
  whichever one they arrived with.
- **Escrow is settled and is not in this list any more.** factory does not hold
  customer key material (2026-08-17); the section above records why. It used to
  add that reversing it would need `deployment-profiles` 8.3 to have actually
  run first — **8.3 ran on 2026-08-23**, so that gate is satisfied and is no
  longer what holds the decision. What holds it now is escrow durability, the
  untested role trap, and one cluster's attestation being unverifiable; see the
  bullets above. The decision itself is unchanged.
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
