## ADDED Requirements

### Requirement: Operator credential is minted once per cluster by the operator company

The direct-LAN `os:operator` talosconfig a cluster's `talos-mcp` sidecar carries SHALL be minted by the operator company — `omnictl talosconfig --cluster <cluster> --break-glass` for Omni-managed clusters, or `talosctl config new --roles os:operator` from the cluster's own PKI for clusters born outside Omni — once per cluster, at provisioning or at the first rotation, through the fleet-ops skill that owns this lifecycle. It SHALL never be minted by, pasted into, or typed at the resident agent.

#### Scenario: Minted through the skill, written file-to-file
- **WHEN** the skill mints the credential for a cluster
- **THEN** the value is written straight into that cluster repo's git-ignored `cluster.yaml` field `talos_operator_config`, the skill prints only the credential's roles, endpoints and `notAfter`, and no tool output or transcript contains the certificate or key

#### Scenario: A second mint is refused while one is current
- **WHEN** the skill is asked to mint for a cluster whose `cluster.yaml` already carries a non-expired operator credential
- **THEN** it refuses and names the existing credential's expiry, unless explicitly told it is rotating after a CA rotation

### Requirement: Credential travels through the standard secret pipeline

The operator credential SHALL reach the sidecar only through the existing path — `cluster.yaml` → CUE-validated optional field → `cluster-secrets.sops.yaml` (`TALOS_OPERATOR_CONFIG_B64`) → Flux substitution into `talos-mcp-secret` → volume subPath on the `talos-mcp` container — and its absence SHALL render a sidecar identical to one that never had the feature.

#### Scenario: Field absent renders a reader-only sidecar
- **WHEN** `cluster.yaml` has no `talos_operator_config`
- **THEN** `task configure` succeeds, the Secret key is empty, the HelmRelease mounts no operator file, and the sidecar registers only the read-only tools

#### Scenario: Field present reaches the sidecar intact
- **WHEN** `cluster.yaml` carries `talos_operator_config` and the cluster is reconciled
- **THEN** `/etc/talos-mcp/operator-talosconfig` inside the sidecar decodes to the same bytes the skill wrote, and `talosctl --talosconfig` on it reports roles `os:operator`

### Requirement: Revocation is CA rotation, not file deletion

The operator credential SHALL be treated as irrevocable by Omni; the only revocation is `omnictl cluster -n <cluster> secret rotate talos-ca` (or the equivalent on a cluster outside Omni), followed by a fresh mint, re-render and pod restart. The skill SHALL perform the rotation, prove the old credential is rejected afterwards, and only then mint the replacement.

#### Scenario: Rotation invalidates the old credential
- **WHEN** the skill rotates the Talos CA for a cluster
- **THEN** a read-only call with the previous operator credential is rejected (`Unauthenticated` or TLS failure), the new credential answers, and the skill records both readings with the rotation timestamp

#### Scenario: Rotation is a rollout, not a hot swap
- **WHEN** the rotation completes
- **THEN** the skill re-mints, writes `cluster.yaml`, runs `task configure`, and stops before the push for the human to authorize; the `im` pod is restarted after the push so the sidecar reads the new file

#### Scenario: Deleting the file does not revoke
- **WHEN** an operator or agent removes the credential file from a pod or repo without rotating the CA
- **THEN** the fleet's records (skill output, `docs/verification-status.md`) still list the credential as live until a rotation is recorded

### Requirement: Tainted is an expected state of a delivered cluster

An Omni-managed cluster that carries an operator credential SHALL carry the `omni.sidero.dev/tainted-by-break-glass` label, and fleet tooling SHALL treat that label as expected rather than as a defect.

#### Scenario: Delivery check does not flag the taint
- **WHEN** `delivery-check.py` or `omni-cluster-lifecycle` inspects a delivered cluster carrying the taint label
- **THEN** the label is reported as informational with the mint date, not as a failing cell

#### Scenario: Omni operations on a tainted cluster are measured before rollout
- **WHEN** the feature is first enabled on any cluster
- **THEN** a throwaway cluster has already been minted, labelled, template-synced, Talos-upgraded and CA-rotated with every step's outcome recorded, before a production cluster is touched

### Requirement: Expiry is surfaced before it bites

The credential's `notAfter` SHALL be visible without reading the credential: the skill prints it at mint and on `verify`, the sidecar prefixes every tool response with a warning when fewer than 30 days remain, and `docs/verification-status.md` lists each cluster's expiry.

#### Scenario: Sidecar warns near expiry
- **WHEN** the operator credential expires in fewer than 30 days
- **THEN** every tool response from the sidecar begins with a line naming the expiry date and the fleet-ops skill that rotates it

#### Scenario: Expired credential reads as absent, loudly
- **WHEN** the operator credential has expired
- **THEN** the sidecar registers no mutating tool, the direct-LAN fallback reports "operator credential expired on <date>" instead of a TLS error, and the read tools keep working through Omni
