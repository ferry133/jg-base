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
      default/
        echo/           ← echo-ext.<domain> / echo-int.<domain> reachability probe
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
        homebridge/
        mariadb/
        mqtt/
        postgres/
        synophoto/
        trello-notifier/
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
>
> `default/echo` is **not** an extra either, as of 2026-08-23 — every cluster answers on
> `echo-ext.<domain>` and `echo-int.<domain>`. See the migration note below.

| Extra | Description | Requires |
|-------|-------------|----------|
| `claudecode/postgres` | Dedicated PostgreSQL for claude-code (MCP memory server) | `claudecode_postgres_password` |
| `default/homebridge` | Homebridge smart home bridge | — |
| `default/mariadb` | MariaDB database | — |
| `default/mqtt` | MQTT broker | — |
| `default/postgres` | Shared PostgreSQL | `postgres_password` |
| `default/synophoto` | Synology photo workflow (GPS tagger + auto-move + AI-curated progress albums). Lives in ns `linebot` to share `linebot-admin` for project metadata (sites table, photo_folder slugs). | `synophoto_flask_secret_key`, `anthropic_api_key` |
| `default/trello-notifier` | Trello LINE notification bot | Trello/LINE tokens |
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

### Do this — retire the old Kustomization through git, in two pushes

> Corrected 2026-08-11. The recipe that stood here (suspend the parent, then
> `kubectl patch spec.prune=false`) was written after the jcom incident and **never
> tested**. It was tried for the first time during the local-path migration and did not
> work: the release was uninstalled anyway. Two independent reasons, below.

The retiring Kustomization has to stop cascading **before** the commit that removes it
lands, and the only place that survives is git.

```sh
# 1. in the per-user repo, set deletionPolicy: Orphan on the Kustomization being
#    retired — edit the rendered ks.yaml (or the template that emits it), push,
#    and wait for it to actually apply:
kubectl -n flux-system get kustomization extras-claude-code \
  -o jsonpath='{.spec.deletionPolicy}{"\n"}'      # must read: Orphan

# 2. only now push jg-base, and in the per-user repo drop the entry from
#    cluster.yaml's extras: — task configure --yes, push
flux reconcile source git jg-base

# 3. verify the new owner adopted the objects, then clear the retired shell
kubectl -n flux-system get kustomization claude-code claude-code-instances daily-check
kubectl -n claudecode  get helmrelease,pod,pvc
```

#### Why `spec.prune: false` does nothing here

`prune` is not the field that governs deletion. From the CRD:

> `deletionPolicy` … Valid values are (`MirrorPrune`, `Delete`, `WaitForTermination`,
> `Orphan`). **`MirrorPrune` mirrors the Prune field** (orphan if false, delete if true).
> Defaults to `MirrorPrune`.

`prune` only reaches the deletion path *through* `MirrorPrune`. Every Kustomization this
template generates explicitly sets `deletionPolicy: WaitForTermination`, so `prune` is
never consulted when the object is deleted — patching it to `false` is a no-op that
reads back exactly as though it worked.

#### When step 1 can be skipped

The Orphan step exists to survive one race: the removal landing before the new owner has
adopted the object. If adoption has *already* happened, the race is over and the wrapper
can simply be deleted. Check the object, not the clock:

```sh
kubectl -n flux-system get kustomization <object> \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}'
# prints the new owner  → safe to remove the old wrapper from git directly
# prints the old owner  → do step 1 first
```

Flux's garbage collection compares that label against the pruning Kustomization's own
identity and skips anything it does not own. Verified on jcom 2026-08-11: the retired
`extras-local-path-provisioner` was removed with no Orphan step and the `local-path`
StorageClass kept its 88-day age — never deleted, never recreated.

#### Why live-patching either field is futile anyway

Both fields are declared in git, so the parent's next server-side apply reverts whatever
was patched in. Suspending the parent to prevent that is not reliable either: it holds
while you watch it, but any reconcile already in flight still lands, and on this stack
`Kustomization/flux-system` is `app.kubernetes.io/managed-by: flux-operator` — a second
controller with its own opinion about that object's spec.

Set it in git, confirm it applied, and only then push the removal.

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

Same race as the 2026-08-07 migration above — the inner Kustomization keeps its name, so
the new owner can adopt it in place, but only if it reconciles before the old owner's
finalizer prunes it. Use the two-push recipe above.

**No data is at risk here**, unlike the claude-code migration: a Helm uninstall of this
release removes the StorageClass, Deployment and RBAC, but local-path PVs are plain
hostPath directories that no controller touches while their PVC still exists. Bound
volumes keep serving through the window — the kubelet mounts them without the
provisioner. What *does* break in that window is provisioning: any new PVC naming
`local-path` sits Pending until the class is back.

That is what made jgt-omni the right cluster to test the runbook on, and it is just as
well: the old recipe failed there and the release *was* uninstalled. Recovery was one
`flux reconcile source git jg-base` — the PVCs never noticed. Observed sequence:

```
extras-local-path-provisioner pruned  → child Kustomization deleted
  → HelmRelease uninstalled           → StorageClass local-path gone, pod Terminating
  → PVCs im-claude-config / im-claude-workspace  still Bound throughout
cluster-apps-base reconciled on the new jg-base revision
  → Kustomization/local-path-provisioner recreated at the base path
  → StorageClass back, provisioner 1/1 Running
```

## Migration: `default/echo` extra → base, split into ext + int (2026-08-23)

`echo` used to be an opt-in extra with a single route on `envoy-external`, named
`echo.<domain>` from the Helm release name. It is now a base app on every cluster and
publishes two names off one pod:

| Name | Gateway | What a 200 from it proves |
|---|---|---|
| `echo-ext.<domain>` | `envoy-external` | the public path — Cloudflare DNS → tunnel → external gateway → a pod |
| `echo-int.<domain>` | `envoy-internal` | the LAN path — k8s-gateway/LAN address → internal gateway → a pod |

The two are worth having separately because they fail separately, and until now a
cluster had no cheap way to say *which* half was down. Both are served by the same
Deployment, so a 200 on one and a timeout on the other is a statement about the path,
not about the workload.

**`echo.<domain>` is gone.** Any check, bookmark or `daily_check_endpoints` entry
pointing at it has to move to `echo-ext.<domain>`.

Objects, before → after:

| Object | before | after |
|---|---|---|
| `Kustomization/echo` (flux-system) | owned by `extras-echo`, path `apps/extras/default/echo` | owned by `cluster-apps-base`, path `apps/base/default/echo` |
| `HelmRelease/echo` (default) | owned by `Kustomization/echo` | **unchanged** |
| `HTTPRoute/echo` | from `route.app` | **replaced** by `echo-ext` + `echo-int` |

Same ownership race as the two migrations above — `Kustomization/echo` keeps its name, so
the new owner can adopt it in place only if it reconciles before the retiring
`extras-echo` finalizer prunes it. Use the two-push recipe in the 2026-08-07 section,
and check the owner label before deciding whether the `deletionPolicy: Orphan` step is
needed.

**Unlike the other two, nothing here is worth protecting.** echo has no PVC and no
state; if it loses the race the release is uninstalled and `cluster-apps-base` puts it
back on the next reconcile. Losing the race costs a few minutes of a debug endpoint, so
on a cluster where the Orphan step is inconvenient, skip it and let it recreate.

Clusters that listed `default/echo` in `cluster.yaml` when this landed: **jcom**,
**jgt-talos-accept**. Every other cluster gains the app with nothing to retire.

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

## NAS backups on a cluster with no NAS

`extras/claudecode/postgres` and `extras/default/postgres` each ship a daily
`pg_dump` CronJob writing to a **separate** NAS backup share — separate from the
live-DB share so it can be ShareSync'd off-site without two-way-syncing live
database files. It needs a hand-rolled `PersistentVolume` because that share is a
different export from the one `nfs-subdir` provisions.

An appliance has no NAS (`cue vet` refuses `appliance` + NAS), so `${NAS_SERVER}`
is empty and the PV is rejected with `spec.nfs.server: Required value`. While that
PV lived in the same kustomization as the database, that single invalid object made
the whole Kustomization `Ready=False` and **the database never deployed at all**
(ferry133/jg-base#17, measured on jg-janncotcc 2026-08-23).

The backup group is now its own Flux Kustomization, selected by directory:

```yaml
path: ./kubernetes/apps/extras/<ns>/postgres/backup/${NAS_BACKUP:=nfs}
```

`backup/nfs/` holds the PV, PVC and CronJob; `backup/none/` is an empty
kustomization that renders zero objects (a clean build, not an error — verified
with both `kustomize build` and `flux build ks --dry-run`).

**Why a dedicated variable rather than `${NAS_SERVER}`.** Flux substitutes with
drone/envsubst, and `${VAR:+alt}` is **not implemented** there — it behaves exactly
like `${VAR:-alt}`. Measured with `flux envsubst` (flux 2.7.4, the same code path):

| written | `NAS_SERVER=10.9.1.12` | `NAS_SERVER=""` |
|---|---|---|
| `${NAS_SERVER:+nfs}` | `10.9.1.12` | `nfs` |
| `${NAS_SERVER:-nfs}` | `10.9.1.12` | `nfs` |

So "value when set, literal when empty" is the only conditional available, and it
cannot express "nfs when NAS_SERVER is set". Do not re-derive this from a shell —
`sh -c 'echo "${VAR:+x}"'` gives the POSIX answer, which is *not* Flux's.

**Why not `${DB_STORAGE_CLASS}`.** It does not mean what it looks like. jg-jiahd has
a NAS (`NAS_SERVER=10.9.2.13`) and `DB_STORAGE_CLASS=longhorn` — databases are kept
off NFS deliberately, so the DB's class says nothing about whether a NAS exists.
Keying on it would have switched jg-jiahd's backup off silently.

**The default is `nfs`, and that is load-bearing.** A cluster whose `cluster-secrets`
predates `NAS_BACKUP` keeps exactly today's behaviour, so nothing loses its backup
because this landed. The cost is the other half of the trade: until
jg-cluster-template derives the value and the cluster re-renders, an appliance still
selects `nfs` and *that one Kustomization* stays `Ready=False`. The database deploys;
the thing that is red is named after the thing that is broken.

**An appliance is not left without a database backup.** `base/monitoring/offsite-backup`
dumps every database, encrypts to the cluster's own age public key and uploads it
off-site — mandatory rather than opt-in, per `deployment-profiles`' appliance-backup
spec. What must NOT be done instead is backing up onto `local-path`: an appliance is
one disk with no redundancy, and a backup on the disk it exists to survive is not a
backup.

**`extras/freepbx/freepbx` is deliberately untouched.** Its `backup.yaml` has the same
`nfs.server: ${NAS_SERVER}` shape, but seven of its live PVCs are hardcoded
`storageClassName: sc-nas`, so it cannot run on an appliance at all. Splitting only its
backup would make it *look* appliance-ready while still failing on the live volumes —
worse than leaving it obviously NAS-only. Parameterising those seven is a separate
change.

## Longhorn backups (optional, off by default)

`defaultReplicaCount: 2` survives a node dying. It does not survive `kubectl delete pvc`
or a corrupt table — both are faithfully replicated to every replica. Until
[#7](https://github.com/ferry133/jg-base/issues/7) the Longhorn layer had no backups at
all: measured on jg-jiahd 2026-08-17, `backuptargets.longhorn.io/default` had an empty
URL and there were zero `recurringjobs`. Note the diagnosis that matters there — the URL
field was **empty, not broken**. Never configured and configured-but-unreachable look
almost the same in the UI and want opposite fixes.

One variable, optional:

```yaml
LONGHORN_BACKUP_TARGET: "nfs://10.9.2.13:/volume3/backup1/longhorn"
```

### A cluster that sets neither renders byte-identically to today

This is the property that lets an `apps/base/` change carry a LAN address that most
clusters cannot reach. It is measured, not assumed — `helm template` of chart 1.12.0,
diffing the **entire** render:

| values | full-render diff vs today |
|---|---|
| `backupTarget:` unset (null) | **no difference at all** |
| `backupTarget: ""` (quoted empty) | `+ backup-target:` |
| `backupTarget: nfs://…` | `+ backup-target: nfs://…` |

Which is why `helmrelease.yaml` writes `backupTarget: ${LONGHORN_BACKUP_TARGET:=}`
**unquoted**. The chart guards each key with `if not (kindIs "invalid" ...)`; a null is
dropped, an empty string is written. Kustomize does not preserve the quotes you write
anyway, so the value domain is the only place this can be controlled — the same trap as
`NODE_DNS_PATH` in `daily-check`, arrived at from the other direction.

### Two things that would have silently done nothing

- **`defaultSettings.backupTarget` does not exist in chart 1.12.0.** The key is
  `defaultBackupStore.backupTarget`; `templates/default-resource.yaml` is what reads it.
  Helm accepts unknown values without complaint, so the wrong key would have produced a
  cluster that looks configured and never backs anything up.
- **`longhorn/ks.yaml` had no `postBuild`.** Flux substitutes nothing at all unless
  `postBuild` is present, so `${LONGHORN_BACKUP_TARGET:=}` would have reached Helm as a
  literal 28-character string and been stored as the backup target URL. Adding a
  `${VAR}` to a manifest is only half the change; the Kustomization that builds it has
  to be asking for substitution.

### Turning it on, and the part that is harder — turning it off

The gate is `Kustomization/longhorn-backup`, which has three states:

| state | shipped by | `suspend` | `path` | applied |
|---|---|---|---|---|
| never asked for | jg-base default | `true` | `backup/enabled` | nothing |
| on | jg-cluster-template patch | `false` | `backup/enabled` | the RecurringJob |
| off, after being on | jg-cluster-template patch | `false` | `backup/**disabled**` | nothing |

The third row is the whole of [#29](https://github.com/ferry133/jg-base/issues/29).
Off is **not** a return to `suspend: true`, because **suspend stops reconciliation; it
does not remove what reconciliation already created.** Measured on a different app in
this repo: 2026-08-19, jcom had `lan-address-probe` suspended with its Deployment still
running 7 days later and a stray `pool-discovered` no Service used.

Suspending to turn backups off would leave `daily-backup` in `longhorn-system` and
silence the only Flux object that would have reported it, in the same instant — an
orphan and its alarm switched off together. #28 refused `dependsOn: [longhorn]` because
an alarm that is always on is an alarm nobody reads; this is the mirror defect, an alarm
that can never go off, and it is worse because the first is at least visible.

What the orphan would then do was written here as **unmeasured, with both answers bad.**
It was measured on jg-jiahd on 2026-08-28, and it is the worse of the two: **clearing the
target in git does not clear the target in the cluster.** The ConfigMap key goes away and
`BackupTarget/default` keeps the URL with `available: true`, so a close path built on
`suspend` would have left the RecurringJob writing to a destination that is still there
and still writable — going on *succeeding*, quietly backing up a cluster whose operator
turned backups off in git and watched the commit merge. Not failing. Failing was the
visible answer, and it was not the real one.

The three measured lines live in `backup-ks.yaml`'s comment, not here — one holder, so
the two cannot drift apart. (They already did once: #33 updated the manifest and left
this paragraph claiming the thing was unmeasured.)

That makes the empty `path` right for a stronger reason than the one it was merged on.
It was chosen to make the question moot; the answer, had anyone asked, was silent
success. The Kustomization keeps reconciling, its inventory goes empty, Flux prunes the
RecurringJob, and the alarm stays armed — and the surviving target has nothing left to
act on it.

A cluster that never turned it on stays on row 1 and is untouched by all of this: an
object that has never reconciled has no `status.conditions`, so daily-check's check 2
counts it as neither passing nor failing.

**If a cluster is retired without re-rendering**, the patch never changes and the
RecurringJob stays. The supported close is to clear `longhorn_backup_target` and
`task configure` — that is what moves the switch to `disabled`.

⚠️ **`kubectl delete recurringjob -n longhorn-system daily-backup` is not a complete
manual close**, and this README said it was until the close path was actually run.
Deleting the job stops the writing; it does not remove the destination.
`BackupTarget/default` keeps the URL with `available: true` — measured, see
`backup-ks.yaml` — so the cluster still holds where its backups went and the
relationship to that share. For a cluster being retired, that is the part that matters.
**What to do about the surviving CR is not established**: whether to delete it, blank
its URL, and whether Longhorn simply recreates it, has not been tested. Do not infer a
command from this paragraph — see the correction on
[#29](https://github.com/ferry133/jg-base/issues/29).

### Why the gate is not `${...}` in the path

The obvious shape — `path: .../backup/${LONGHORN_BACKUP:=disabled}`, which is what
`extras/*/postgres` does — kills CI:

```
ERROR: Kustomization 'flux-system/longhorn-backup' path field
'...backup/${LONGHORN_BACKUP:=none}' is not a directory
```

`cluster-apps` walks `./kubernetes/apps/base` and nothing else, so every Kustomization
under `base/` is collected by `flux-local test`, which substitutes nothing and dies at
collection, taking all 37 tests with it. The extras precedent survives only because
extras are never reachable from `apps/base`, so CI has never walked one — **untested
there, not proven.** Keeping a literal path is also what lets flux-local build and
validate the RecurringJob on every PR.

`backup-ks.yaml` deliberately has **no `dependsOn: [longhorn]`**. It would not close the
race it appears to close — `longhorn` runs with `wait: false` and does not wait on its
HelmRelease, so it is Ready long before the CRD exists — and it would cost a permanent
not-Ready row on every cluster where `longhorn` is suspended, because a Flux
Kustomization depending on a suspended one waits forever. `retryInterval: 5m` covers the
real case instead.

### Not verified

- **Nothing has been backed up or restored.** The NAS export `/volume3/backup1` is known
  to accept the existing `pg_dump` writes from a root pod, and Longhorn's
  instance-manager also runs as root, so it *should* be writable — but no Longhorn
  backup has been taken and none has been restored. A backup target that has never
  restored is a hypothesis. `/volume3/backup1/longhorn` does not exist on the NAS yet.
- **The cron is in UTC by inference.** Longhorn sets no `spec.timeZone` on the CronJobs
  it renders, so `0 18 * * *` should fire at 02:00 Asia/Taipei. Read from the source and
  the CronJob default, not observed on a running cluster.
- **Whether an already-running Longhorn picks the target up without a manager restart.**
  The chart writes it into the `longhorn-default-resource` ConfigMap, which
  longhorn-manager reads by name; default-resource values are documented as applying to
  settings the user has not overridden. jg-jiahd has never set this one, so it should
  apply — untested. Check with
  `kubectl get backuptargets.longhorn.io -n longhorn-system -o wide`.

## CI: `flux-local` and Secret `data:` placeholders

`.github/workflows/flux-local.yaml` builds every Kustomization and HelmRelease in the
repo. flux-local does that by shelling out to `flux build ks … --dry-run`, and the flux
CLI is explicit about that mode:

> Note that variable substitutions from Secrets and ConfigMaps are skipped in dry-run mode.

So a `${VAR}` placeholder inside a Secret's **`data:`** field survives into the built
object, and flux then base64-decodes every `data:` value looking for sops ciphertext:

```go
data, err := base64.StdEncoding.DecodeString(v)
if corruptErr := base64.CorruptInputError(0); errors.As(err, &corruptErr) {
    return corruptErr
}
```

`$` is not in the base64 alphabet, so the build fails — **and in flux-local that happens
during collection, so every other Kustomization in the repo goes unvalidated too.** The
run ends with `no tests ran`, which on the PR page is one red cross that looks like any
other red cross. This repo shipped in that state from at least 2026-08-18 to 2026-08-23.

There is no configuration escape: no Flux substitution syntax is base64-safe, flux-local
always uses `flux build`, and its `--skip-secrets` (on by default) filters the *output*,
long after the build has already failed. So CI rewrites those values to `""` before
running flux-local, via `.github/scripts/stub-secret-data-placeholders.py`. This costs
nothing in coverage — flux-local discards Secret contents anyway — and the manifests in
git are untouched.

Run it yourself before blaming a manifest:

```sh
python3 .github/scripts/stub-secret-data-placeholders.py --check kubernetes
```

**`stringData:` is not affected** — flux only base64-decodes `data:`. A new Secret that
needs a Flux-substituted value should prefer `stringData:` for exactly this reason;
`data:` is only correct when the variable already holds base64 that must reach the
container decoded (today: `talos-mcp-secret`'s `talosconfig`, `omni-gpg-key`'s
`omni.asc`).

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
