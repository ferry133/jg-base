# omni-platform Specification

## Purpose
TBD - created by archiving change upgrade-omni-server-v1-8. Update Purpose after archive.
## Requirements
### Requirement: Omni Server Version Tracks Upstream

The deployed Omni server SHALL run image `ghcr.io/siderolabs/omni:v1.8.1` after this change, and the deployment manifest SHALL pin the image tag explicitly (never `latest`).

#### Scenario: Pod runs the pinned version
- **WHEN** an operator runs `kubectl -n omni get pod -l app.kubernetes.io/name=omni -o jsonpath='{.items[0].spec.containers[0].image}'` against the `jcom` cluster
- **THEN** the output MUST be exactly `ghcr.io/siderolabs/omni:v1.8.1`

#### Scenario: HelmRelease pins the image tag
- **WHEN** an operator reads `kubernetes/apps/extras/omni/omni/app/helmrelease.yaml`
- **THEN** the file MUST contain `tag: "v1.8.1"` under `values.image`

### Requirement: Helm Chart Fork Matches Upstream v1.8.1

The user-maintained Helm chart at `~/coding/helm-charts/charts/omni/` SHALL be regenerated from the upstream `siderolabs/omni` repository at git tag `v1.8.1`, with chart `version` and `appVersion` bumped accordingly, and published to `https://ferry133.github.io/helm-charts` before the in-cluster HelmRelease is updated.

#### Scenario: Chart appVersion matches deployed image
- **WHEN** an operator reads `~/coding/helm-charts/charts/omni/Chart.yaml`
- **THEN** `appVersion` MUST equal `"v1.8.1"` (matching the image tag in the HelmRelease)

#### Scenario: Published chart is reachable
- **WHEN** Flux's `my-helm-repo` HelmRepository in the `omni` namespace performs its next sync
- **THEN** the new chart version MUST appear in the index at `https://ferry133.github.io/helm-charts/index.yaml`
- **AND** the version string MUST be greater than `2.1.1` (the previously published version)

### Requirement: EULA Acceptance Recorded in Configuration

Starting with Omni `v1.7.0`, the server refuses to start without EULA acceptance. The HelmRelease values SHALL declare acceptance via `config.eulaAccept` with a real operator name and email; placeholder values are NOT allowed.

#### Scenario: HelmRelease declares EULA acceptance
- **WHEN** an operator reads the HelmRelease values
- **THEN** `values.config.eulaAccept.name` MUST be a non-empty string identifying a real operator (e.g., `ferry133`)
- **AND** `values.config.eulaAccept.email` MUST be a valid email address belonging to that operator

#### Scenario: Server starts without EULA error
- **WHEN** the Omni pod starts after the upgrade
- **THEN** the container logs MUST NOT contain any `EULA not accepted` error
- **AND** the Omni HTTP endpoint MUST return 200 OK on `/`

### Requirement: omnictl PGP Keypair Auth Bootstraps Cleanly

After the upgrade, a fresh `omnictl get clusters` invocation with no pre-existing PGP key at `~/.talos/keys/default-<identity>.pgp` SHALL trigger the auto-generation + registration flow (printing a registration URL to stdout) rather than failing with `no such file or directory`.

**Status:** Implementation revealed this requirement is **not satisfiable by the Omni server upgrade alone**. The omnictl renewal flow's `RegisterPGPPublicKey` succeeds server-side, but the subsequent `AwaitPublicKeyConfirmation` streaming RPC fails client-side with `rpc error: code = Internal desc = server closed the stream without sending trailers` — caused by the cloudflared tunnel proxying `omni.janncot.com` without the `service: grpc://` scheme. Resolution is tracked in a separate change (`fix-cloudflared-grpc-omni`). The two scenarios below describe the **target behavior** post-cloudflared-fix; they are not validated by this change.

#### Scenario: First-call keygen with missing PGP key (deferred to follow-up)
- **WHEN** the operator deletes any stale `~/.talos/keys/*.pgp` files and runs `omnictl get clusters --omniconfig ~/.talos/omni/config`
- **THEN** `omnictl` MUST either succeed (if a valid key exists server-side already) OR print a URL beginning with `https://omni.janncot.com/` for the operator to complete registration in a browser
- **AND** the command MUST NOT fail with the literal string `no such file or directory`

#### Scenario: Post-registration calls succeed (deferred to follow-up)
- **WHEN** the operator completes the browser registration flow once and re-runs `omnictl get clusters`
- **THEN** the command MUST list the cluster `jgu5-control-planes` (or whatever clusters Omni manages) without re-prompting for authentication

### Requirement: Omni State Survives Pod Restarts

The Omni server's persistent state (etcd, cluster registry, identity records) SHALL be stored in a PVC and SHALL survive pod recreations during chart upgrades.

#### Scenario: Identity record persists across upgrade
- **WHEN** the upgrade completes and the new pod is `Ready`
- **THEN** the identity `ferry133@gmail.com` MUST still be present on the server (verified via Omni UI or `omnictl get identities` once auth is working)
- **AND** the managed cluster `jgu5-control-planes` MUST still appear in `omnictl get clusters`

### Requirement: Upgrade Procedure Is Documented

A README at `kubernetes/apps/extras/omni/omni/README.md` SHALL document the operator runbook for future major Omni version upgrades, including: refreshing the local Omni source clone, regenerating the chart fork from upstream, bumping chart version, republishing to GitHub Pages, and updating the HelmRelease.

#### Scenario: README exists with required sections
- **WHEN** an operator reads the README
- **THEN** the file MUST contain sections covering: (a) refreshing `~/coding/omni`, (b) regenerating `~/coding/helm-charts/charts/omni`, (c) chart version bump rules, (d) HelmRelease update steps, (e) verification commands, (f) rollback procedure

### Requirement: Omni Reachable via Configured Ingress

The Omni server SHALL be reachable at three endpoints — `https://omni.janncot.com` (UI + API), `https://omni-k8s.janncot.com` (kube API proxy), `https://omni-siderolink.janncot.duckdns.org` (SideroLink) — with each `advertisedURL` in `config.services` matching the actual reachable URL after upgrade.

#### Scenario: Main UI endpoint reachable
- **WHEN** an operator performs `curl -sI https://omni.janncot.com/`
- **THEN** the response MUST be `HTTP/2 200` or a redirect that ultimately reaches `200`

#### Scenario: SideroLink wireguard endpoint reachable
- **WHEN** the SideroLink-managed Talos machines in `jg-jiahd` are checked
- **THEN** they MUST report `Connected=true` to Omni via `omni-wireguard` after the upgrade

