## Context

The Omni control plane in `jcom` was bootstrapped on 2026-05-14 with Helm chart `2.1.1` (forked into `~/coding/helm-charts/charts/omni`) pinning image `ghcr.io/siderolabs/omni:v1.6.4`. The chart's published `appVersion` of `v1.5.3` is a stale placeholder — the override in the consuming HelmRelease wins. The local source clone at `~/coding/omni` is on upstream `main` and **2 commits ahead** of any tag we've pinned to. The `omnictl` client on the Mac was upgraded by Homebrew to `v1.8.1` (current upstream), creating a 2-minor-version split between client and server. This split breaks the `siderov1` PGP-key auto-bootstrap and blocks Talos artifact export for disaster recovery (the trigger that surfaced the problem).

Three repos are involved:

```
┌─ siderolabs/omni (upstream, no write access) ────────────────┐
│   ~/coding/omni  (local clone, tracks main)                  │
│                                                              │
│   ├── deploy/helm/omni/         ← canonical chart source     │
│   └── (binaries / image)        ← published to ghcr.io       │
│                                                              │
└──────────────────────────────────────────────────────────────┘
            │ copy at tagged release
            ▼
┌─ ferry133/helm-charts (our fork & redistribution) ───────────┐
│   ~/coding/helm-charts/charts/omni/                          │
│   index.yaml + .tgz published via GitHub Pages               │
│   URL: https://ferry133.github.io/helm-charts                │
└──────────────────────────────────────────────────────────────┘
            │ Flux HelmRepository
            ▼
┌─ ferry133/jg-base (cluster manifests) ───────────────────────┐
│   kubernetes/apps/extras/omni/omni/app/helmrelease.yaml      │
│   pins chart version + image tag + values                    │
└──────────────────────────────────────────────────────────────┘
            │ Flux reconcile (jcom)
            ▼
   Running pod in `omni` namespace
```

Constraints:
- Single-replica deployment (embedded etcd). No active/standby — downtime is unavoidable but bounded.
- Persistent state in a PVC (`local-pvc.yaml` + `nfs-pvc.yaml`). Upgrade MUST NOT touch PVCs.
- We are 2 minor versions behind. Upstream upgrade docs need confirming whether `v1.6 → v1.8` is supported in one step or requires a `v1.7` stop.
- The `omni-config` Secret currently has no `eulaAccept` block — `v1.7.0` mandated it. Pod will not start after upgrade without it.

## Goals / Non-Goals

**Goals:**
- Bring deployed Omni server to `v1.8.1` (matching upstream latest and the local `omnictl`).
- Refresh the chart fork at `~/coding/helm-charts/charts/omni` from upstream `deploy/helm/omni` at tag `v1.8.1`, with disciplined version bumps and a republish to GitHub Pages.
- Update the in-cluster HelmRelease to pull the new chart and accept the EULA.
- Verify the `siderov1` PGP auto-keygen flow works post-upgrade, unblocking the parked P1 Talos export task.
- Document the operator runbook so the next major upgrade is mechanical, not investigative.

**Non-Goals:**
- 2-node → 3-node etcd HA expansion for `jg-jiahd` (tracked separately; this proposal only touches the Omni control plane, not workload-cluster Talos topology).
- Switching Omni auth provider (we stay on auth0 OIDC + `siderov1`).
- Multi-replica Omni HA (upstream still says single replica only).
- Moving Omni state from PVC to external storage (S3, etc.).
- Per-user repo cleanup of `~/coding/jcom/omni-helm` (only contains an orphan `tls.key`, low value to address now).

## Decisions

### D1: One-step upgrade `v1.6.4 → v1.8.1` (no `v1.7.x` stopover)

Upstream release notes for `v1.7.0` and `v1.8.0` list breaking changes (EULA, join-tokens default) but neither mandates a multi-step migration path. We will read both release notes end-to-end during the chart regen step (T2) and confirm; if a stopover is required, escalate via Open Question OQ-1.

**Alternative:** `v1.6.4 → v1.7.3 → v1.8.1` two-step. Rejected because it doubles downtime and offers no measurable safety benefit if upstream supports the direct jump.

### D2: Regenerate chart by copy-from-upstream, not by manual diff

The simplest faithful sync is `rm -rf charts/omni/* && cp -r ~/coding/omni/deploy/helm/omni/* charts/omni/`, then re-apply any local-only modifications (we should review whether there are any) and bump chart `version`. This avoids drift from cherry-picking individual commits.

**Alternative:** `git merge` from a hypothetical upstream-tracked branch. Rejected because the chart is currently a snapshot copy, not a tracked fork.

### D3: Chart `version` bump strategy: `2.1.1 → 3.0.0`

The upstream chart at `v1.8.1` may differ structurally from our snapshot of `v1.5.3`-era upstream — `values.yaml` schema changes, template restructuring, helm chart `apiVersion`/dependencies changes. Treat as a major bump for the chart-fork consumers. Caveat: we are the only consumer.

**Alternative:** Mirror upstream chart version directly (whatever number Sidero stamps it). Tabled — to check what version upstream uses at `v1.8.1`'s `deploy/helm/omni/Chart.yaml`. If they ship `version: 2.x.y` we'll match that; if `3.x.y`, even better.

### D4: EULA acceptance values — use ferry133's name and email

`config.eulaAccept.name: "ferry133"` and `config.eulaAccept.email: "ferry133@gmail.com"` (matching the existing Omni identity record). Stored in plaintext in `helmrelease.yaml` (not a secret — EULA acceptance is a public legal record).

**Alternative:** Move to `omni-config` Secret. Rejected; EULA acceptance is not sensitive.

### D5: `~/coding/omni` is git-pulled to upstream `main`, not pinned to `v1.8.1` tag

`~/coding/omni` exists as a reference clone, not a built artifact. After upgrade it can stay on `main` (or move forward freely) because it does not produce the deployed image (`ghcr.io/siderolabs/omni:v1.8.1` is pulled by k8s directly from Sidero's registry). The chart regen step **does** need the `v1.8.1` tag checked out temporarily.

```sh
cd ~/coding/omni
git fetch --tags
git checkout v1.8.1                 # detached HEAD is fine
# ... copy deploy/helm/omni/ → ~/coding/helm-charts/charts/omni/
git checkout main                   # restore
```

### D6: Republish workflow uses the existing `~/coding/helm-charts` push-to-Pages flow

Whatever mechanism currently publishes `index.yaml` + `.tgz` to GitHub Pages (likely a `helm package` + `helm repo index` + commit step) is reused as-is. To confirm during T3, look for any `Makefile` / `Taskfile.yaml` / GitHub Actions workflow in `~/coding/helm-charts`.

### D7: Verification gating — `omnictl get clusters` must succeed before declaring done

A pod that is `Ready` is necessary but not sufficient. The whole driver for this work is the broken auth flow, so we explicitly add a verification step: run `omnictl get clusters` (after PGP key re-bootstrap if needed) and confirm a non-empty cluster list. If this step fails, the upgrade is not complete and we either troubleshoot or roll back.

### D8: Rollback by reverting HelmRelease, keeping chart history

Chart `2.1.1` artifacts remain in GitHub Pages `index.yaml` history; we do not delete them. Rollback = revert the HelmRelease commit and Flux re-pulls the old chart. PVC data is preserved.

## Risks / Trade-offs

- **R1: Chart `v1.8.1` upstream schema differs from our snapshot → existing values.yaml overrides break**  
  → Mitigation: do a dry-run `helm template` of the new chart with our HelmRelease values *before* republishing, catch unknown-key errors early.

- **R2: Direct v1.6 → v1.8 jump triggers a hidden migration we missed**  
  → Mitigation: read `v1.7.0` + `v1.8.0` release notes fully (in T2); explicitly check for any "Urgent Upgrade Notes" section we haven't acknowledged.

- **R3: Persistent PVC data has v1.6-era schema; v1.8 may migrate it in place, and v1.6 then can't read the migrated state — so a HelmRelease revert alone is not a full rollback**  
  → Mitigation: take a `tar czf` snapshot of `/data` from the running v1.6.4 pod **before** any push that could trigger Flux to roll out v1.8.1 (the Flux HelmRelease has `interval: 15m`, so the snapshot must precede the `git push`, not merely precede the manual Phase 6 reconcile). The snapshot can be re-loaded into the same PVC via a sidecar busybox pod if v1.6.4 ever needs to be restored. Implemented as Task 5.6 (snapshot) and Task 10.5 (restore).

- **R4: GitHub Pages chart republish race — Flux picks up old `index.yaml` cache**  
  → Mitigation: explicitly trigger HelmRepository reconcile (`flux reconcile source helm my-helm-repo -n omni`) after the push commits.

- **R5: EULA wording change between v1.7 and v1.8 — we accept terms we haven't read**  
  → Mitigation: read https://siderolabs.com/eula/ once before the operator name is recorded.

- **R6: omnictl PGP flow still fails post-upgrade (something else is wrong)**  
  → Mitigation: have a Plan B inside the verification step — try the web UI download path for talosconfig if PGP still won't bootstrap. This unblocks the downstream task even if the *cause* needs more digging.

## Migration Plan

Logical phases (concrete commands live in `tasks.md`):

1. **Pre-flight** — confirm cluster healthy, PVC bound, etcd happy. Snapshot current HelmRelease + chart version in commit message for rollback reference.
2. **Source refresh** — `git fetch --tags && git checkout v1.8.1` in `~/coding/omni`.
3. **Chart regen** — copy upstream `deploy/helm/omni/` into `~/coding/helm-charts/charts/omni/`, bump `version`, set `appVersion: "v1.8.1"`.
4. **Dry-run** — `helm template` the new chart with our overrides; surface schema breaks.
5. **Republish** — commit, push, and trigger / wait for GitHub Pages rebuild; verify `index.yaml` reachable.
6. **HelmRelease update** — edit `helmrelease.yaml` in `jg-base`, bump chart version, image tag, add `eulaAccept`.
7. **Reconcile** — `flux reconcile source helm my-helm-repo -n omni`, then `flux reconcile helmrelease omni -n omni`.
8. **Verify** — pod ready, logs clean, UI reachable, `omnictl get clusters` succeeds.
9. **Document** — write README.md operator runbook.
10. **Close out** — un-park the Talos export P1 task (now unblocked).

**Rollback:** revert HelmRelease commit, `flux reconcile`, Flux pulls chart `2.1.1` back. PVC data intact.

## Open Questions

- **OQ-1**: Does upstream confirm `v1.6.4 → v1.8.1` is supported in one step? → Resolve by reading `v1.7.0` + `v1.8.0` release notes' Urgent Upgrade Notes sections in T2; if not, switch to two-step plan and update tasks.
- **OQ-2**: What chart `version` does upstream stamp on `deploy/helm/omni/Chart.yaml` at the `v1.8.1` tag? → Resolve in T2 (`git show v1.8.1:deploy/helm/omni/Chart.yaml`); align our bump accordingly.
- **OQ-3**: Does `~/coding/helm-charts` have any local-only modifications to the omni chart we need to preserve (custom templates, value tweaks)? → Resolve by `diff` between our current `charts/omni/` and the same files at `~/coding/omni` `v1.5.3` tag.
- **OQ-4**: Does the existing chart publish workflow auto-run on push, or does it require a manual `helm package` step? → Resolve by inspecting `~/coding/helm-charts` repo root (Taskfile / Makefile / `.github/workflows/`).
