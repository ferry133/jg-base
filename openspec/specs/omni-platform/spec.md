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

`omnictl` SHALL bootstrap a PGP keypair automatically on first invocation: when no key exists at `~/.talos/keys/default-<identity>.pgp`, the renewal flow MUST register a fresh public key with the server, write the matching private key to disk, and either succeed or print a browser confirmation URL — rather than failing with `no such file or directory`. This requirement was deferred during `upgrade-omni-server-v1-8` pending the transport-layer fix introduced by this change; with trailer propagation restored (see `External gRPC Calls to Omni Preserve HTTP/2 Trailers`), the two scenarios below are now expected to pass end-to-end.

#### Scenario: First-call keygen with missing PGP key
- **WHEN** the operator deletes any stale `~/.talos/keys/*.pgp` files and runs `omnictl get clusters --omniconfig ~/.talos/omni/config`
- **THEN** `omnictl` MUST either succeed (if a valid key exists server-side already) OR print a URL beginning with `https://omni.janncot.com/` for the operator to complete registration in a browser
- **AND** the command MUST NOT fail with the literal string `no such file or directory`
- **AND** after the command exits, the file `~/.talos/keys/default-<identity>.pgp` MUST exist on disk (the WriteKey step in `renewUserKeyViaAuthFlow` must complete)

#### Scenario: Post-registration calls succeed
- **WHEN** the operator completes the browser registration flow once and re-runs `omnictl get clusters`
- **THEN** the command MUST list the cluster `jgu5-control-planes` (or whatever clusters Omni manages) without re-prompting for authentication

### Requirement: Omni State Survives Pod Restarts

The Omni server's persistent state (etcd, cluster registry, identity records) SHALL be stored in a PVC and SHALL survive pod recreations during chart upgrades.

#### Scenario: Identity record persists across upgrade
- **WHEN** the upgrade completes and the new pod is `Ready`
- **THEN** the identity `ferry133@gmail.com` MUST still be present on the server (verified via Omni UI or `omnictl get identities` once auth is working)
- **AND** the managed cluster `jgu5-control-planes` MUST still appear in `omnictl get clusters`

### Requirement: Upgrade Procedure Is Documented

A README at `kubernetes/apps/extras/omni/omni/README.md` SHALL document the
operator runbook for future major Omni version upgrades, including:
refreshing the local Omni source clone, regenerating the chart fork from
upstream, bumping chart version, republishing to GitHub Pages, and updating
the HelmRelease. The README's troubleshooting section SHALL also document the
gRPC trailer propagation expectation introduced by this change so that future
ingress-layer changes do not silently regress it.

#### Scenario: README exists with required sections
- **WHEN** an operator reads the README
- **THEN** the file MUST contain sections covering: (a) refreshing `~/coding/omni`, (b) regenerating `~/coding/helm-charts/charts/omni`, (c) chart version bump rules, (d) HelmRelease update steps, (e) verification commands, (f) rollback procedure

#### Scenario: README documents gRPC trailer expectation
- **WHEN** an operator reads the troubleshooting section of the README after this change is archived
- **THEN** the omnictl-auth section MUST mark the cloudflared gRPC limitation as resolved
- **AND** MUST reference this change (`fix-cloudflared-grpc-omni`) and explain (briefly) which configuration change(s) restored trailer propagation, so the next operator changing the ingress layer knows what to preserve

### Requirement: Omni Reachable via Configured Ingress

The Omni server SHALL be reachable at three endpoints — `https://omni.janncot.com` (UI + API), `https://omni-k8s.janncot.com` (kube API proxy), `https://omni-siderolink.janncot.duckdns.org` (SideroLink) — with each `advertisedURL` in `config.services` matching the actual reachable URL after upgrade.

#### Scenario: Main UI endpoint reachable
- **WHEN** an operator performs `curl -sI https://omni.janncot.com/`
- **THEN** the response MUST be `HTTP/2 200` or a redirect that ultimately reaches `200`

#### Scenario: SideroLink wireguard endpoint reachable
- **WHEN** the SideroLink-managed Talos machines in `jg-jiahd` are checked
- **THEN** they MUST report `Connected=true` to Omni via `omni-wireguard` after the upgrade

### Requirement: External gRPC Calls to Omni Preserve HTTP/2 Trailers

The ingress path from external clients to the Omni server SHALL preserve HTTP/2 response trailers for all gRPC method invocations on `omni.janncot.com`, covering both unary and server-streaming methods. Specifically, after this change:

- Unary RPCs such as `auth.AuthService/RegisterPublicKey` MUST return a
  client-observable `grpc.code: OK` (matching the server-side log) when the
  server processes them successfully — not `rpc error: code = Internal desc =
  server closed the stream without sending trailers`.
- Server-streaming RPCs such as `auth.AuthService/AwaitPublicKeyConfirmation`
  MUST be able to receive at least one message and observe the end-of-stream
  trailer cleanly.

This requirement applies to traffic flowing through the public hostname
`omni.janncot.com` (cloudflared tunnel → envoy-external Gateway →
`omni.omni.svc:8080`). Traffic on `omni-siderolink.janncot.duckdns.org`, which
uses a separate nginx ingress with `backend-protocol: GRPC`, already satisfies
this property and is outside the scope of this change.

#### Scenario: omnictl RegisterPublicKey unary call returns OK to client
- **WHEN** an operator runs `omnictl get clusters --omniconfig ~/.talos/omni/config` with no pre-existing PGP key file
- **THEN** the operator MUST NOT see the literal string `server closed the stream without sending trailers` in the client output
- **AND** the server-side log entry for `auth.AuthService/RegisterPublicKey` (visible via `kubectl -n omni logs deploy/omni`) MUST match the client observation (both OK, or both an explicit gRPC status code other than `Internal`)

#### Scenario: HTTP (non-gRPC) traffic on the same hostname remains healthy
- **WHEN** an operator runs `curl -sI https://omni.janncot.com/` after the fix is applied
- **THEN** the response MUST still be `HTTP/2 200` (the Web UI must not regress as a side-effect of the gRPC fix)

