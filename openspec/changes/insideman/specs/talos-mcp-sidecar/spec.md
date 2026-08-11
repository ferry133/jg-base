## ADDED Requirements

### Requirement: Isolated Talos credential per client
Each `claude_instances` pod that has a Talos MCP sidecar enabled SHALL hold a Talos client credential scoped to the `os:reader` role, unique to that client's own cluster, distinct from the operator's shared break-glass credential.

#### Scenario: Credential is cluster-specific
- **WHEN** a Talos credential is bootstrapped for a client during onboarding
- **THEN** the resulting client certificate is scoped to that client's own Talos cluster CA and cannot authenticate against any other cluster's Talos API

#### Scenario: Credential role is read-only
- **WHEN** the `talos-mcp` sidecar's credential attempts a mutating Talos API call (e.g. reboot, config apply, upgrade)
- **THEN** the Talos API server rejects the call based on the `os:reader` role embedded in the client certificate, independent of what the calling code requests

### Requirement: Credential isolated from the agent shell
The Talos credential SHALL be mounted only into the `talos-mcp` sidecar container's own filesystem/environment, never into the `app` container where the terminal user and Claude Code agent process run.

#### Scenario: Agent shell cannot read the credential
- **WHEN** a user or the Claude Code agent runs a shell command inside the `app` container (e.g. `cat`, `env`, `ls`)
- **THEN** no path or environment variable in that container exposes the Talos credential's raw contents

#### Scenario: Sidecar reachable only within the pod
- **WHEN** the `talos-mcp` sidecar's MCP server is running
- **THEN** it is bound to a loopback address reachable only from other containers in the same pod, not from the client's LAN or the public internet

### Requirement: Read-only Talos diagnostic tools available via MCP
The `app` container's Claude Code agent SHALL have access, via a registered remote MCP server, to read-only Talos diagnostic tools: node status, etcd member list, network link status (SideroLink/KubeSpan), and service logs.

#### Scenario: Agent queries node status without operator involvement
- **WHEN** the Claude Code agent in a ttyd session calls the Talos MCP `get_node_status` tool for a node in its own cluster
- **THEN** it receives the node's Talos version/health status without any credential being supplied by, or visible to, the remote operator

#### Scenario: Agent diagnoses a SideroLink-style connectivity issue unassisted
- **WHEN** the Claude Code agent calls `get_link_status` and `get_etcd_members` for nodes in its own cluster
- **THEN** it receives link state and etcd membership data sufficient to distinguish "node/cluster unhealthy" from "management-plane connectivity issue," without the remote operator generating or transmitting any Talos credential

### Requirement: No mutating Talos capability introduced
This capability SHALL NOT provide any tool or code path capable of issuing a mutating Talos API call.

#### Scenario: No reboot/upgrade/apply-config tool exists
- **WHEN** the Talos MCP server's tool list is inspected
- **THEN** it contains only read-only diagnostic tools; no tool capable of rebooting a node, applying configuration, or upgrading Talos is present
