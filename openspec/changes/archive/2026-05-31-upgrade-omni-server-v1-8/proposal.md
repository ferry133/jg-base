## Why

The deployed Omni server at `https://omni.janncot.com` (in `jcom` cluster) runs `ghcr.io/siderolabs/omni:v1.6.4`, while the local `omnictl` client on ferry133's Mac has been upgraded to `v1.8.1`. The 2-minor-version gap (server lags client by `v1.7.0` + `v1.8.0` minor releases) breaks the `siderov1` PGP keypair auto-bootstrap flow: `omnictl get ...` fails with `Could not authenticate: open ~/.talos/keys/default-ferry133@gmail.com.pgp: no such file or directory` and the client never offers to generate / register the missing key.

This blocks all Talos artifact export from Omni — including the P1 "export `jg-jiahd` Talos config for disaster recovery" task — and also leaves the server two minors behind on security / feature fixes (EULA enforcement landed in `v1.7.0`, join-token mode default changed in `v1.8.0`).

The user-maintained Helm chart at [`~/coding/helm-charts/charts/omni`](../../../helm-charts/charts/omni) is a fork of the upstream chart at [`~/coding/omni/deploy/helm/omni`](../../../omni/deploy/helm/omni), currently at chart `v2.1.1` / `appVersion: v1.5.3`. To upgrade the running server we must first refresh the chart fork from upstream's `v1.8.1` tag and republish to `https://ferry133.github.io/helm-charts`.

## What Changes

- **BREAKING (operator-only)**: `omnictl` v1.6.4 ↔ v1.8.1 client/server mismatch resolved by upgrading server (not by downgrading client). Operators using older `omnictl` binaries will need to upgrade.
- Refresh local Omni source clone at `~/coding/omni/` from upstream `siderolabs/omni` to tag `v1.8.1`.
- Regenerate user Helm chart at `~/coding/helm-charts/charts/omni/` from upstream `deploy/helm/omni/` at the `v1.8.1` tag; bump chart `version` and `appVersion` accordingly; commit and republish to `ferry133.github.io/helm-charts`.
- Update Flux `HelmRelease` at [`kubernetes/apps/extras/omni/omni/app/helmrelease.yaml`](../../../kubernetes/apps/extras/omni/omni/app/helmrelease.yaml) in `jg-base`:
  - Bump `chart.spec.version` to the new published chart version.
  - Override `image.tag: "v1.8.1"`.
  - Add **EULA acceptance** in `values.config.eulaAccept` (`name`, `email`) — required by `v1.7.0+`.
  - Verify `auth0` OIDC settings still work (no schema change anticipated, but confirm).
- After server upgrade: re-run `omnictl get clusters --omniconfig ~/.talos/omni/config` to verify the PGP keypair bootstrap flow now triggers correctly.
- Document the upgrade procedure in [`kubernetes/apps/extras/omni/omni/README.md`](../../../kubernetes/apps/extras/omni/omni/README.md) (new file) so future major upgrades can follow the same steps.

**Out of scope** (tracked separately):
- 2-node → 3-node etcd HA expansion for the Omni-managed cluster (`jg-jiahd`). Surfaced from server logs as `Etcd members count is equal to the minimum quorum 2`, but is a Talos-side change, not Omni-side.
- Per-user repo `~/coding/jcom/omni-helm/` cleanup (orphan `tls.key` only; not load-bearing).

## Capabilities

### New Capabilities

- `omni-platform`: the self-hosted Sidero Omni control-plane deployment in `jcom` (running image, Helm chart fork, Flux HelmRelease values, ingress + SideroLink endpoints, auth provider config). Encodes the contract for *what version of Omni is deployed, how it is configured, and how operators authenticate to it*.

### Modified Capabilities

(none — no pre-existing specs in `openspec/specs/`.)

## Impact

**Code / config touched:**

- `~/coding/omni/` (source clone) — git fetch + checkout `v1.8.1` tag. No edits.
- `~/coding/helm-charts/charts/omni/` — full chart contents replaced from upstream `v1.8.1`; chart `version` bumped; commit + push triggers GitHub Pages republish.
- `jg-base/kubernetes/apps/extras/omni/omni/app/helmrelease.yaml` — chart version bump, image tag override, `eulaAccept` block added.
- `jg-base/kubernetes/apps/extras/omni/omni/README.md` — new operator runbook.

**Cluster impact:**

- Single-replica Omni deployment in `omni` namespace, `jcom` cluster — restart on upgrade (~30-60s downtime for Omni UI / API).
- Talos clusters managed by Omni (`jg-jiahd`) stay running during Omni downtime (Omni is control-plane only; workload clusters operate independently).
- Persistent data: Omni state is in PVC (`local-pvc.yaml`) — upgrade must preserve.

**External:**

- `ferry133.github.io/helm-charts` republished — any other consumer of this chart fork picks up the new version on their next Flux sync.
- EULA acceptance is binding for the listed name/email — confirm wording before adding.

**Risk:**

- v1.6 → v1.8 skips one minor (v1.7). Upstream upgrade docs need review for any intermediate migration steps.
- Chart 2.1.1 → upstream's current chart version may include schema changes affecting other values we override.
- Rollback plan: revert HelmRelease commit + republish previous chart version (chart history preserved via GitHub Pages).
